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
    @ObservationIgnored private var flushTask: Task<Void, Never>?
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
        // without the master's times and rule, a series write would move the whole series to this
        // occurrence's date and drop its exceptions
        if toSeries, series == nil, fields?["start"] != nil || draft.recurrence != original.recurrence
            || (moved && draft.account != original.account) {
            error = "Couldn't save “\(draft.summary)”: the repeating event couldn't be loaded. Try again when online."
            return
        }

        var updated = event.applying(draft)
        updated.calendarId = original.calendarId
        updated.account = original.account
        if var fields {
            if toSeries, let series, draft.recurrence != original.recurrence {
                fields["recurrence"] = RecurrenceRule.replacing(draft.recurrence, in: series.recurrence, allDay: draft.allDay)
            }
            enqueue(PendingWrite(
                account: event.account, calendarId: event.calendarId, eventId: targetId, method: "PATCH",
                path: GoogleCalendarAPI.eventPath(calendarId: event.calendarId, eventId: targetId),
                query: ["sendUpdates": Self.sendUpdates(event)], body: fields,
                ifMatch: toSeries ? series?.etag : event.etag, refreshSeries: toSeries ? targetId : nil,
                summary: draft.summary, createdAt: now()))
        }
        if moved {
            enqueueMove(event: event, targetId: targetId, draft: draft, toSeries: toSeries, series: series)
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
    private func enqueueMove(event: EventInstance, targetId: String, draft: EventDraft, toSeries: Bool, series: Series?) {
        if draft.account == event.account {
            enqueue(PendingWrite(
                account: event.account, calendarId: event.calendarId, eventId: targetId, method: "POST",
                path: GoogleCalendarAPI.eventPath(calendarId: event.calendarId, eventId: targetId) + "/move",
                query: ["destination": draft.calendarId, "sendUpdates": Self.sendUpdates(event)],
                refreshSeries: toSeries ? targetId : nil, summary: draft.summary, createdAt: now()))
        } else {
            var copy = draft
            if let series, toSeries {
                // the series' first occurrence, shifted as far as this occurrence moved
                copy.start = series.start.addingTimeInterval(draft.start.timeIntervalSince(event.start))
                copy.end = series.end.addingTimeInterval(draft.end.timeIntervalSince(event.end))
            } else if event.recurringEventId != nil && !toSeries {
                // one occurrence moves alone, as a one-off event
                copy.recurrence = nil
            }
            var body = copy.insertBody()
            if let series, toSeries { body["recurrence"] = RecurrenceRule.replacing(draft.recurrence, in: series.recurrence, allDay: draft.allDay) }
            var insert = PendingWrite(
                account: draft.account, calendarId: draft.calendarId, eventId: targetId, method: "POST",
                path: GoogleCalendarAPI.eventPath(calendarId: draft.calendarId), query: ["sendUpdates": "none"],
                body: body, summary: draft.summary, createdAt: now())
            insert.replaces = event.id
            enqueue(insert)
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

    /// Sends queued writes in order until the queue is empty or the network fails. A call made while
    /// a flush runs waits for that flush, so a sync that follows never overtakes an unsent write.
    public func flush() async {
        if let running = flushTask {
            await running.value
            return
        }
        // cleared in the same step that finds the queue empty, so a write queued after that starts a new flush
        let task = Task {
            await drain()
            flushTask = nil
        }
        flushTask = task
        await task.value
    }

    private func drain() async {
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
                await dropDependents(of: write)
                continue
            }
            // rate limits and server errors are temporary: the write waits for the next flush
            if status == 429 || (500..<600).contains(status) { break }
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
                await dropDependents(of: write)
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
                    await dropDependents(of: write)
                }
            }
        }
        if changed { engine.onChange() }
    }

    /// Later writes to the same event assumed the dropped one succeeded (the delete half of a move
    /// to another account, an edit made on top of it), so they are dropped too and the cache
    /// takes Google's copy of what they touched.
    private func dropDependents(of write: PendingWrite) async {
        guard let dependents = try? cache.removeWrites(eventId: write.eventId) else { return }
        for d in dependents where d.account != write.account || d.calendarId != write.calendarId {
            await refetch(d)
        }
    }

    /// A write Google accepted: its response becomes the cached event.
    private func landed(_ write: PendingWrite, data: Data) async {
        if write.path.hasSuffix("/move") {
            try? cache.deleteEvent(account: write.account, calendarId: write.calendarId, id: write.eventId,
                                   series: write.refreshSeries)
        }
        // writes queued behind this one were made against the version it replaced
        if write.method != "DELETE", let etag = try? JSONDecoder().decode(GoogleCalendarAPI.GoogleEvent.self, from: data).etag {
            try? cache.updateQueuedIfMatch(eventId: write.eventId, to: etag)
        }
        if let series = write.refreshSeries {
            let calendarId = write.query["destination"] ?? write.calendarId
            await engine.refreshSeries(series, account: write.account, calendarId: calendarId)
        } else if write.method != "DELETE",
                  let g = try? JSONDecoder().decode(GoogleCalendarAPI.GoogleEvent.self, from: data) {
            let calendarId = write.query["destination"] ?? write.calendarId
            if let placeholder = write.replaces {
                try? cache.deleteEvent(account: write.account, calendarId: calendarId, id: placeholder)
            }
            if g.isRecurringMaster {
                // an inserted series: its occurrences, not the master, belong in the cache
                await engine.refreshSeries(g.id, account: write.account, calendarId: calendarId)
            } else if let instance = g.instance(account: write.account, calendarId: calendarId) {
                try? cache.upsert([instance])
            }
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
