// Edits, RSVPs, deletes and undo (§6, §8.1, §8.2), written through a persistent queue (§18.3).
//
// Every write changes the cache first, so the UI shows the result at once, then joins the queue.
// The queue sends writes in order. On success the server's copy of the event replaces the cache's.
// On 412 (the event changed elsewhere) or another rejection, Kalendar refetches the event, drops
// the write and reports it. On a network failure the write waits for the next flush.
import Foundation
import Observation

@MainActor
@Observable
public final class EventWriter {
    /// What a recurring event's edit, RSVP or delete applies to (§8.1).
    public enum Scope { case occurrence, series }

    /// The last write that failed, for the UI to show; cleared by `clearError()`.
    public private(set) var error: String?
    /// The last delete, while it can be undone (⌘Z, §8.2).
    public private(set) var undoableDelete: EventInstance?

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let cache: CalendarCache
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var lastDeleteScope: Scope = .occurrence

    public init(accounts: AccountStore, cache: CalendarCache, engine: SyncEngine, now: @escaping () -> Date = Date.init) {
        self.accounts = accounts
        self.cache = cache
        self.engine = engine
        self.now = now
    }

    public func clearError() { error = nil }

    // MARK: Reading

    /// A recurring series' master event: its rule, times and etag. nil offline or for a one-off.
    public struct Series {
        public var rule: RecurrenceRule?
        public var recurrence: [String]
        public var start: Date
        public var end: Date
        public var etag: String?
    }

    public func series(of event: EventInstance) async -> Series? {
        guard let master = event.recurringEventId,
              let g = try? await accounts.calendarAPI(GoogleCalendarAPI.GoogleEvent.self, for: event.account,
                  GoogleCalendarAPI.getEventRequest(calendarId: event.calendarId, eventId: master)),
              let instance = g.instance(account: event.account, calendarId: event.calendarId)
        else { return nil }
        return Series(rule: g.recurrence.flatMap(RecurrenceRule.init(recurrence:)), recurrence: g.recurrence ?? [],
                      start: instance.start, end: instance.end, etag: g.etag)
    }

    // MARK: Writes

    /// Saves the detail popover's edits. `series` is the master's data when `scope` is `.series`.
    public func save(_ event: EventInstance, original: EventDraft, draft: EventDraft, scope: Scope, series: Series?) {
        let toSeries = scope == .series && event.recurringEventId != nil
        let targetId = toSeries ? event.recurringEventId! : event.id
        // a repeat change always belongs to the series (or the one-off becoming one)
        let fields = draft.patchBody(from: original, seriesTimes: toSeries ? series.map { ($0.start, $0.end) } : nil)
        let moved = draft.calendarKey != original.calendarKey

        var updated = event.applying(draft)
        updated.calendarId = original.calendarId
        updated.account = original.account
        if var fields {
            if toSeries, let series, draft.recurrence != original.recurrence {
                fields["recurrence"] = RecurrenceRule.replacing(draft.recurrence, in: series.recurrence)
            }
            enqueue(PendingWrite(
                account: event.account, calendarId: event.calendarId, eventId: targetId, method: "PATCH",
                path: GoogleCalendarAPI.eventPath(calendarId: event.calendarId, eventId: targetId),
                query: ["sendUpdates": Self.sendUpdates(event)], body: fields,
                ifMatch: toSeries ? series?.etag : event.etag, refreshSeries: toSeries ? targetId : nil,
                summary: draft.summary, createdAt: now()))
        }
        if moved {
            enqueueMove(event: event, targetId: targetId, draft: draft, toSeries: toSeries)
            updated.account = draft.account
            updated.calendarId = draft.calendarId
        }
        try? cache.deleteEvent(account: event.account, calendarId: event.calendarId, id: event.id)
        try? cache.upsert([updated])
        engine.onChange()
        Task { await flush() }
    }

    /// Same account: `events.move`. Another account: insert a copy there, then delete the original
    /// (offered only for events the user organizes, §6.1).
    private func enqueueMove(event: EventInstance, targetId: String, draft: EventDraft, toSeries: Bool) {
        if draft.account == event.account {
            enqueue(PendingWrite(
                account: event.account, calendarId: event.calendarId, eventId: targetId, method: "POST",
                path: GoogleCalendarAPI.eventPath(calendarId: event.calendarId, eventId: targetId) + "/move",
                query: ["destination": draft.calendarId, "sendUpdates": Self.sendUpdates(event)],
                refreshSeries: toSeries ? targetId : nil, summary: draft.summary, createdAt: now()))
        } else {
            enqueue(PendingWrite(
                account: draft.account, calendarId: draft.calendarId, eventId: targetId, method: "POST",
                path: GoogleCalendarAPI.eventPath(calendarId: draft.calendarId), query: ["sendUpdates": "none"],
                body: draft.insertBody(), summary: draft.summary, createdAt: now()))
            enqueue(PendingWrite(
                account: event.account, calendarId: event.calendarId, eventId: targetId, method: "DELETE",
                path: GoogleCalendarAPI.eventPath(calendarId: event.calendarId, eventId: targetId),
                query: ["sendUpdates": "none"], refreshSeries: toSeries ? targetId : nil,
                summary: draft.summary, createdAt: now()))
        }
    }

    /// Accept / Decline / Maybe (§6, §6.2): `accepted`, `declined` or `tentative`.
    public func respond(_ event: EventInstance, response: String, scope: Scope) {
        let toSeries = scope == .series && event.recurringEventId != nil
        let targetId = toSeries ? event.recurringEventId! : event.id
        enqueue(PendingWrite(
            account: event.account, calendarId: event.calendarId, eventId: targetId, method: "PATCH",
            path: GoogleCalendarAPI.eventPath(calendarId: event.calendarId, eventId: targetId),
            query: ["sendUpdates": "all"], body: EventDraft.rsvpBody(attendees: event.attendees, response: response),
            refreshSeries: toSeries ? targetId : nil, summary: event.summary, createdAt: now()))
        var updated = event
        updated.selfResponse = response
        updated.attendees = event.attendees.map { a in
            var a = a
            if a.isSelf { a.responseStatus = response }
            return a
        }
        try? cache.upsert([updated])
        engine.onChange()
        Task { await flush() }
    }

    public func delete(_ event: EventInstance, scope: Scope) {
        let toSeries = scope == .series && event.recurringEventId != nil
        let targetId = toSeries ? event.recurringEventId! : event.id
        enqueue(PendingWrite(
            account: event.account, calendarId: event.calendarId, eventId: targetId, method: "DELETE",
            path: GoogleCalendarAPI.eventPath(calendarId: event.calendarId, eventId: targetId),
            query: ["sendUpdates": Self.sendUpdates(event)], summary: event.summary, createdAt: now()))
        try? cache.deleteEvent(account: event.account, calendarId: event.calendarId, id: event.id,
                               series: toSeries ? targetId : nil)
        // an invitation someone else organized cannot be restored by Kalendar (§8.2)
        undoableDelete = event.organizerSelf || event.attendees.isEmpty ? event : nil
        lastDeleteScope = toSeries ? .series : .occurrence
        engine.onChange()
        Task { await flush() }
    }

    /// Restores the last delete: the cancelled event back to `confirmed`, or, if Google refuses
    /// that, a copy inserted without re-sending invitations (§8.2).
    public func undoDelete() {
        guard let event = undoableDelete else { return }
        undoableDelete = nil
        let toSeries = lastDeleteScope == .series
        let targetId = toSeries ? event.recurringEventId! : event.id
        var copy = EventDraft(event, recurrence: nil).insertBody()
        copy["attendees"] = nil
        enqueue(PendingWrite(
            account: event.account, calendarId: event.calendarId, eventId: targetId, method: "PATCH",
            path: GoogleCalendarAPI.eventPath(calendarId: event.calendarId, eventId: targetId),
            query: ["sendUpdates": "none"], body: ["status": "confirmed"],
            refreshSeries: toSeries ? targetId : nil, fallbackBody: copy, summary: event.summary, createdAt: now()))
        try? cache.upsert([event])
        engine.onChange()
        Task { await flush() }
    }

    /// Duplicate (§7.1): a copy of this occurrence on the same calendar, without its guests.
    public func duplicate(_ event: EventInstance) {
        var body = EventDraft(event, recurrence: nil).insertBody()
        body["attendees"] = nil
        enqueue(PendingWrite(
            account: event.account, calendarId: event.calendarId, eventId: event.id, method: "POST",
            path: GoogleCalendarAPI.eventPath(calendarId: event.calendarId), query: ["sendUpdates": "none"],
            body: body, summary: event.summary, createdAt: now()))
        Task { await flush() }
    }

    /// Guests hear about changes to events the user organizes; nobody hears about changes to an
    /// event without guests or to the user's copy of someone else's invitation.
    static func sendUpdates(_ event: EventInstance) -> String {
        event.organizerSelf && event.attendees.count > 1 ? "all" : "none"
    }

    private func enqueue(_ write: PendingWrite) {
        do { try cache.enqueue(write) } catch {
            self.error = "Couldn't save “\(write.summary)”: \(error.localizedDescription)"
        }
    }

    // MARK: Sending

    /// Sends queued writes in order until the queue is empty or the network fails.
    public func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        var changed = false
        while let write = try? cache.nextWrite(), let id = write.id {
            let data: Data, status: Int
            do {
                (data, status) = try await accounts.sendAuthorized(for: write.account, GoogleCalendarAPI.writeRequest(write))
            } catch is URLError {
                break   // offline: try again on the next flush
            } catch GoogleOAuth.Error.invalidGrant {
                break   // the account must sign in again; the write waits
            } catch {
                report(write, error.localizedDescription)
                try? cache.removeWrite(id)
                continue
            }
            try? cache.removeWrite(id)
            changed = true
            // 410 on a delete: already gone, which is what the delete wanted
            let accepted = (200..<300).contains(status) || (status == 410 && write.method == "DELETE")
            switch status {
            case _ where accepted:
                await landed(write, data: data)
            case 412:
                report(write, nil)
                await refetch(write)
            default:
                if let fallback = write.fallbackBody {
                    // undo of a delete: Google refused to restore the event, so insert a copy
                    try? cache.enqueue(PendingWrite(
                        account: write.account, calendarId: write.calendarId, eventId: write.eventId, method: "POST",
                        path: GoogleCalendarAPI.eventPath(calendarId: write.calendarId), query: ["sendUpdates": "none"],
                        summary: write.summary, createdAt: now()).with(body: fallback))
                } else {
                    report(write, GoogleCalendarAPI.APIError.http(status).localizedDescription)
                    await refetch(write)
                }
            }
        }
        if changed { engine.onChange() }
    }

    /// A write Google accepted: its response becomes the cached event.
    private func landed(_ write: PendingWrite, data: Data) async {
        if write.path.hasSuffix("/move") {
            try? cache.deleteEvent(account: write.account, calendarId: write.calendarId, id: write.eventId)
        }
        if let series = write.refreshSeries {
            let calendarId = write.query["destination"] ?? write.calendarId
            await engine.refreshSeries(series, account: write.account, calendarId: calendarId)
        } else if write.method != "DELETE",
                  let g = try? JSONDecoder().decode(GoogleCalendarAPI.GoogleEvent.self, from: data),
                  let instance = g.instance(account: write.account, calendarId: write.query["destination"] ?? write.calendarId) {
            try? cache.upsert([instance])
        }
    }

    /// The cache's copy of the event after a rejected write: whatever Google has now.
    private func refetch(_ write: PendingWrite) async {
        if let series = write.refreshSeries {
            await engine.refreshSeries(series, account: write.account, calendarId: write.calendarId)
            return
        }
        do {
            let g = try await accounts.calendarAPI(GoogleCalendarAPI.GoogleEvent.self, for: write.account,
                GoogleCalendarAPI.getEventRequest(calendarId: write.calendarId, eventId: write.eventId))
            if let instance = g.instance(account: write.account, calendarId: write.calendarId) {
                try? cache.upsert([instance])
            } else {
                try? cache.deleteEvent(account: write.account, calendarId: write.calendarId, id: write.eventId)
            }
        } catch GoogleCalendarAPI.APIError.notFound {
            try? cache.deleteEvent(account: write.account, calendarId: write.calendarId, id: write.eventId)
        } catch {}
    }

    private func report(_ write: PendingWrite, _ reason: String?) {
        let title = write.summary.isEmpty ? "the event" : "“\(write.summary)”"
        error = reason.map { "Couldn't save \(title): \($0)" }
            ?? "\(title.prefix(1).uppercased() + title.dropFirst()) changed in Google Calendar, so your edit wasn't saved."
    }
}

extension PendingWrite {
    func with(body: Data) -> PendingWrite {
        var w = self
        w.body = body
        return w
    }
}

extension EventInstance {
    /// This occurrence with a draft's edits, for the cache until Google's copy arrives.
    func applying(_ d: EventDraft) -> EventInstance {
        var e = self
        e.summary = d.summary.isEmpty ? "(No title)" : d.summary
        e.location = d.location.isEmpty ? nil : d.location
        e.notes = d.notes.isEmpty ? nil : d.notes
        e.allDay = d.allDay
        e.start = d.start
        e.end = d.end
        e.timeZone = d.timeZone
        e.colorId = d.colorId
        e.transparency = d.busy ? "opaque" : "transparent"
        e.visibility = d.visibility
        e.reminders = d.reminders
        e.attendees = d.attendees
        return e
    }
}
