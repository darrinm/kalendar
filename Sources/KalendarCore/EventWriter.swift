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

    @ObservationIgnored let accounts: AccountStore
    @ObservationIgnored let cache: CalendarCache
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored let now: () -> Date
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
        let target = Self.target(event, scope)
        let toSeries = target.series != nil
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
            let query = ["sendUpdates": Self.sendUpdates(event)].merging(EventDraft.conferenceQuery(fields)) { a, _ in a }
            enqueue(queued("PATCH", event, id: target.id, query: query, body: fields,
                           ifMatch: toSeries ? series?.etag : event.etag, refreshSeries: target.series,
                           summary: draft.summary))
        }
        if moved {
            enqueueMove(event: event, target: target, draft: draft, series: series)
            updated.account = draft.account
            updated.calendarId = draft.calendarId
        }
        // a move takes the event off the calendar for every account that caches it; an edit in place
        // replaces only this account's copy, and the others refresh at their next sync
        try? cache.deleteEvent(account: moved ? nil : event.account, calendarId: event.calendarId, id: event.id)
        try? cache.upsert([updated])
        engine.onChange()
        Task { await flush() }
    }

    /// Same account: `events.move`. Another account: insert a copy there, then delete the original
    /// (offered only for events the user organizes, §6.1).
    private func enqueueMove(event: EventInstance, target: Target, draft: EventDraft, series: Series?) {
        if draft.account == event.account {
            enqueue(queued("POST", event, id: target.id, suffix: "/move",
                           query: ["destination": draft.calendarId, "sendUpdates": Self.sendUpdates(event)],
                           refreshSeries: target.series, summary: draft.summary))
            return
        }
        var copy = draft
        if let series, target.series != nil {
            // the series' first occurrence, shifted as far as this occurrence moved
            copy.start = series.start.addingTimeInterval(draft.start.timeIntervalSince(event.start))
            copy.end = series.end.addingTimeInterval(draft.end.timeIntervalSince(event.end))
        } else if event.recurringEventId != nil {
            // one occurrence moves alone, as a one-off event
            copy.recurrence = nil
        }
        var body = copy.insertBody()
        if let series, target.series != nil {
            body["recurrence"] = RecurrenceRule.replacing(draft.recurrence, in: series.recurrence, allDay: draft.allDay)
        }
        var insert = PendingWrite(
            account: draft.account, calendarId: draft.calendarId, eventId: target.id, method: "POST",
            path: GoogleCalendarAPI.eventPath(calendarId: draft.calendarId),
            query: ["sendUpdates": "none"].merging(EventDraft.conferenceQuery(body)) { a, _ in a },
            body: body, summary: draft.summary, createdAt: now())
        insert.replaces = event.id
        enqueue(insert)
        enqueue(queued("DELETE", event, id: target.id, query: ["sendUpdates": "none"], refreshSeries: target.series,
                       summary: draft.summary))
    }

    /// Accept / Decline / Maybe (§6, §6.2): `accepted`, `declined` or `tentative`.
    public func respond(_ event: EventInstance, response: String, scope: Scope) {
        let target = Self.target(event, scope)
        let attendees = event.attendees.responding(response)
        enqueue(queued("PATCH", event, id: target.id, query: ["sendUpdates": "all"],
                       body: ["attendees": attendees.map(EventDraft.attendee)], refreshSeries: target.series))
        var updated = event
        updated.selfResponse = response
        updated.attendees = attendees
        try? cache.upsert([updated])
        engine.onChange()
        Task { await flush() }
    }

    public func delete(_ event: EventInstance, scope: Scope) {
        let target = Self.target(event, scope)
        enqueue(queued("DELETE", event, id: target.id, query: ["sendUpdates": Self.sendUpdates(event)]))
        try? cache.deleteEvent(calendarId: event.calendarId, id: event.id, series: target.series)
        // an invitation someone else organized cannot be restored by Kalendar (§8.2)
        undoableDelete = event.isInvitation ? nil : event
        lastDeleteScope = target.series == nil ? .occurrence : .series
        engine.onChange()
        Task { await flush() }
    }

    /// Restores the last delete: the cancelled event back to `confirmed`, or, if Google refuses
    /// that, a copy inserted without re-sending invitations (§8.2).
    public func undoDelete() {
        guard let event = undoableDelete else { return }
        undoableDelete = nil
        let target = Self.target(event, lastDeleteScope)
        enqueue(queued("PATCH", event, id: target.id, query: ["sendUpdates": "none"], body: ["status": "confirmed"],
                       refreshSeries: target.series, fallbackBody: EventDraft(event, recurrence: nil).insertBody(guests: false)))
        try? cache.upsert([event])
        engine.onChange()
        Task { await flush() }
    }

    /// A new event from the input form (§5.4): cached at once under a placeholder id that Google's
    /// copy replaces when the insert lands. Invitees are emailed (`sendUpdates=all`, §5.1).
    public func insert(_ draft: EventDraft) {
        let placeholder = Self.placeholderId()
        let body = draft.insertBody()
        var write = PendingWrite(
            account: draft.account, calendarId: draft.calendarId, eventId: placeholder, method: "POST",
            path: GoogleCalendarAPI.eventPath(calendarId: draft.calendarId),
            query: ["sendUpdates": draft.attendees.count > 1 ? "all" : "none"]
                .merging(EventDraft.conferenceQuery(body)) { a, _ in a },
            body: body, summary: draft.summary, createdAt: now())
        write.replaces = placeholder
        enqueue(write)
        try? cache.upsert([EventInstance(placeholder: placeholder, draft: draft)])
        engine.onChange()
        Task { await flush() }
    }

    /// A new item's id until Google's copy arrives.
    static func placeholderId() -> String { "local-\(UUID().uuidString)" }

    /// Duplicate (§7.1): a copy of this occurrence on the same calendar, without its guests.
    public func duplicate(_ event: EventInstance) {
        enqueue(queued("POST", event, id: event.id, insert: true, query: ["sendUpdates": "none"],
                       body: EventDraft(event, recurrence: nil).insertBody(guests: false)))
        Task { await flush() }
    }

    /// Guests hear about changes to events the user organizes; nobody hears about changes to an
    /// event without guests or to the user's copy of someone else's invitation.
    static func sendUpdates(_ event: EventInstance) -> String {
        event.organizerSelf && event.attendees.count > 1 ? "all" : "none"
    }

    /// The event a write goes to: this occurrence, or for `.series` the master; `series` is the
    /// master id to refetch once the write lands.
    struct Target { var id: String; var series: String? }

    static func target(_ event: EventInstance, _ scope: Scope) -> Target {
        if scope == .series, let master = event.recurringEventId { return Target(id: master, series: master) }
        return Target(id: event.id, series: nil)
    }

    /// A write on `event`'s calendar about event `id`; `insert` posts to the calendar's events instead.
    private func queued(_ method: String, _ event: EventInstance, id: String, insert: Bool = false, suffix: String = "",
                        query: [String: String], body: [String: Any]? = nil, ifMatch: String? = nil,
                        refreshSeries: String? = nil, fallbackBody: [String: Any]? = nil,
                        summary: String? = nil) -> PendingWrite {
        PendingWrite(account: event.account, calendarId: event.calendarId, eventId: id, method: method,
                     path: GoogleCalendarAPI.eventPath(calendarId: event.calendarId, eventId: insert ? nil : id) + suffix,
                     query: query, body: body, ifMatch: ifMatch, refreshSeries: refreshSeries,
                     fallbackBody: fallbackBody, summary: summary ?? event.summary, createdAt: now())
    }

    func enqueue(_ write: PendingWrite) {
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
            // 404 or 410 on a delete: already gone, which is what the delete wanted
            let accepted = (200..<300).contains(status) || (write.method == "DELETE" && (status == 404 || status == 410))
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
                    var insert = write
                    insert.id = nil
                    insert.method = "POST"
                    insert.path = GoogleCalendarAPI.eventPath(calendarId: write.calendarId)
                    insert.query = ["sendUpdates": "none"]
                    insert.body = fallback
                    insert.fallbackBody = nil
                    insert.ifMatch = nil
                    insert.refreshSeries = nil
                    try? cache.enqueue(insert)
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
        if write.isTask { return landedTask(write, data: data) }
        let calendarId = write.query["destination"] ?? write.calendarId
        var g = write.method == "DELETE" ? nil : try? JSONDecoder().decode(GoogleCalendarAPI.GoogleEvent.self, from: data)
        // Google attaches a requested conference after answering, which changes the event's etag;
        // the copy fetched now carries the etag the next edit must send
        if write.query["conferenceDataVersion"] != nil, let id = g?.id,
           let fresh = try? await accounts.calendarAPI(GoogleCalendarAPI.GoogleEvent.self, for: write.account,
               GoogleCalendarAPI.getEventRequest(calendarId: calendarId, eventId: id)) {
            g = fresh
        }
        // writes queued behind this one were made against the version it replaced
        if let etag = g?.etag { try? cache.updateQueuedIfMatch(eventId: write.eventId, to: etag) }
        if write.path.hasSuffix("/move") {
            try? cache.deleteEvent(calendarId: write.calendarId, id: write.eventId,
                                   series: write.refreshSeries)
        }
        if let series = write.refreshSeries {
            await engine.refreshSeries(series, account: write.account, calendarId: calendarId)
            return
        }
        guard let g else { return }
        if let placeholder = write.replaces {
            try? cache.deleteEvent(calendarId: calendarId, id: placeholder)
            try? cache.retargetQueued(account: write.account, calendarId: calendarId, from: placeholder, to: g.id)
        }
        if g.isRecurringMaster {
            // an inserted series: its occurrences, not the master, belong in the cache
            await engine.refreshSeries(g.id, account: write.account, calendarId: calendarId)
        } else if let instance = g.instance(account: write.account, calendarId: calendarId) {
            try? cache.upsert([instance])
        }
    }

    /// The cache's copy of the event after a rejected write: whatever Google has now. The optimistic
    /// delete or edit removed every account's copy (`deleteEvent`), and a rejected write leaves the
    /// event unchanged in Google, so no account's next incremental sync would return it. Each
    /// account that caches the calendar refetches its own copy.
    private func refetch(_ write: PendingWrite) async {
        if write.isTask { return await refetchTask(write) }
        let others = ((try? cache.calendars()) ?? [])
            .filter { $0.id == write.calendarId && $0.account != write.account }.map(\.account)
        for account in [write.account] + others {
            await refetch(write, account: account)
        }
    }

    private func refetch(_ write: PendingWrite, account: String) async {
        if let series = write.refreshSeries {
            await engine.refreshSeries(series, account: account, calendarId: write.calendarId)
            return
        }
        do {
            let g = try await accounts.calendarAPI(GoogleCalendarAPI.GoogleEvent.self, for: account,
                GoogleCalendarAPI.getEventRequest(calendarId: write.calendarId, eventId: write.eventId))
            if let instance = g.instance(account: account, calendarId: write.calendarId) {
                try? cache.upsert([instance])
            } else {
                // this account's copy only: another account's refetch may already have restored its own
                try? cache.deleteEvent(account: account, calendarId: write.calendarId, id: write.eventId)
            }
        } catch GoogleCalendarAPI.APIError.notFound {
            try? cache.deleteEvent(account: account, calendarId: write.calendarId, id: write.eventId)
        } catch {}
    }

    private func report(_ write: PendingWrite, _ reason: String?) {
        let (noun, service) = write.isTask ? ("the task", "Google Tasks") : ("the event", "Google Calendar")
        let title = write.summary.isEmpty ? noun : "“\(write.summary)”"
        error = reason.map { "Couldn't save \(title): \($0)" }
            ?? "\(title.prefix(1).uppercased() + title.dropFirst()) changed in \(service), so your edit wasn't saved."
    }
}

extension EventInstance {
    /// A new event as the cache shows it until Google's copy arrives.
    public init(placeholder id: String, draft d: EventDraft) {
        self.init(account: d.account, calendarId: d.calendarId, id: id, recurringEventId: nil,
                  summary: "", location: nil, notes: nil, start: d.start, end: d.end, allDay: d.allDay,
                  transparency: nil, colorId: nil, conferenceURL: nil, selfResponse: nil, organizerSelf: true,
                  attendees: [], htmlLink: nil, etag: nil, visibility: nil, reminders: Reminders(), timeZone: nil)
        self = applying(d)
    }

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
