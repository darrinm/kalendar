// Keeps the cache in step with Google Calendar (§18.3).
//
// Per calendar:
// - First sync: fetch expanded instances for the window (today −1 year … +1 year), then page
//   through every event, ids only, to get a sync token for the change stream.
// - Incremental sync: read the change stream (`singleEvents=false`). A changed single event is
//   upserted or deleted. A change to a recurring master or to one of its exceptions refetches that
//   series' instances for the window, so the cache never has to expand recurrence rules itself.
// - A 410 (expired token), or a window more than 30 days stale, starts over with a first sync.
import Foundation
import Observation

@MainActor
@Observable
public final class SyncEngine {
    public enum State: Equatable {
        case idle
        case syncing
        /// The last sync failed for at least one account; the cache still shows what it had.
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Bumped whenever the cache changed, so views re-read it.
    public private(set) var revision = 0
    /// Called after every cache change, on the main actor.
    @ObservationIgnored public var onChange: () -> Void = {}
    /// When the last sync finished, successfully or not.
    public private(set) var lastSync: Date?

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let cache: CalendarCache
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Visibility writes still in flight, by calendar key. A sync that fetched the calendar list
    /// before the write landed would otherwise put the old value back.
    @ObservationIgnored private var pendingSelected: [String: Bool] = [:]
    @ObservationIgnored private var pending = false

    static let windowRadius: TimeInterval = 365 * 86400
    static let staleWindow: TimeInterval = 30 * 86400

    public init(accounts: AccountStore, cache: CalendarCache, now: @escaping () -> Date = Date.init) {
        self.accounts = accounts
        self.cache = cache
        self.now = now
    }

    /// Syncs every signed-in account. A call while a sync runs schedules exactly one more after it.
    public func syncAll() async {
        if let running {
            pending = true
            await running.value
            return
        }
        let task = Task { await self.runAll() }
        running = task
        await task.value
        running = nil
        if pending {
            pending = false
            await syncAll()
        }
    }

    /// Tells observers the cache changed outside a sync (visibility toggled, account removed).
    public func noteCacheChanged() { changed() }

    private func runAll() async {
        state = .syncing
        var failure: String?
        for account in accounts.accounts where !account.needsReauth {
            do {
                try await sync(account: account.email)
            } catch {
                Log.sync.error("sync \(account.email, privacy: .private) failed: \(error.localizedDescription)")
                failure = error.localizedDescription
            }
            // signed out while this account synced: drop what the sync wrote after sign-out deleted it
            if !accounts.accounts.contains(where: { $0.email == account.email }) {
                try? cache.deleteAccount(account.email)
                changed()
            }
        }
        state = failure.map(State.failed) ?? .idle
        lastSync = now()
    }

    func sync(account: String) async throws {
        var listed: [CalendarInfo] = []
        var page: String?
        repeat {
            let r = try await accounts.calendarAPI(GoogleCalendarAPI.CalendarListPage.self, for: account,
                                                   GoogleCalendarAPI.calendarListRequest(pageToken: page))
            listed += r.calendars(account: account)
            page = r.nextPageToken
        } while page != nil
        for i in listed.indices {
            if let selected = pendingSelected[listed[i].key] { listed[i].selected = selected }
        }
        try cache.replaceCalendars(listed, account: account)
        changed()

        if try !cache.hasEventColors(account: account) {
            let colors = try await accounts.calendarAPI(GoogleCalendarAPI.ColorsResponse.self, for: account,
                                                        GoogleCalendarAPI.colorsRequest())
            try cache.replaceEventColors(colors.colors(account: account), account: account)
        }

        // a free/busy-only calendar returns no event details, so there is nothing to show
        for calendar in try cache.calendars(account: account) where calendar.accessRole != "freeBusyReader" {
            try await sync(calendar: calendar)
        }
    }

    func sync(calendar: CalendarInfo) async throws {
        let stale = calendar.windowStart.map { now().timeIntervalSince($0) > Self.windowRadius + Self.staleWindow } ?? true
        guard let token = calendar.syncToken, !stale else {
            try await fullSync(calendar)
            return
        }
        do {
            try await incrementalSync(calendar, token: token)
        } catch GoogleCalendarAPI.APIError.syncTokenExpired {
            try await fullSync(calendar)
        }
    }

    private func fullSync(_ calendar: CalendarInfo) async throws {
        let from = Calendar.current.startOfDay(for: now()).addingTimeInterval(-Self.windowRadius)
        let to = from.addingTimeInterval(2 * Self.windowRadius)

        // token first: a change made while the window downloads is then replayed by the next
        // incremental sync instead of falling between the two passes
        var token: String?
        var page: String?
        repeat {
            let r = try await events(calendar, GoogleCalendarAPI.tokenPassRequest(calendarId: calendar.id, pageToken: page))
            token = r.nextSyncToken ?? token
            page = r.nextPageToken
        } while page != nil

        var instances: [EventInstance] = []
        page = nil
        repeat {
            let r = try await events(calendar, GoogleCalendarAPI.windowRequest(
                calendarId: calendar.id, from: from, to: to, pageToken: page))
            instances += (r.items ?? []).compactMap { $0.instance(account: calendar.account, calendarId: calendar.id) }
            page = r.nextPageToken
        } while page != nil

        try cache.replaceEvents(instances, account: calendar.account, calendarId: calendar.id)
        var updated = calendar
        updated.syncToken = token
        updated.windowStart = from
        updated.windowEnd = to
        try cache.saveCalendar(updated)
        changed()
    }

    private func incrementalSync(_ calendar: CalendarInfo, token: String) async throws {
        var items: [GoogleCalendarAPI.GoogleEvent] = []
        var nextToken = token
        var page: String?
        repeat {
            let r = try await events(calendar, GoogleCalendarAPI.changesRequest(
                calendarId: calendar.id, syncToken: token, pageToken: page))
            items += r.items ?? []
            nextToken = r.nextSyncToken ?? nextToken
            page = r.nextPageToken
        } while page != nil
        guard !items.isEmpty else {
            if nextToken != token {
                var updated = calendar
                updated.syncToken = nextToken
                try cache.saveCalendar(updated)
            }
            return
        }

        var upserts: [EventInstance] = []
        var deleted = Set<String>()
        var series = Set<String>()
        for item in items {
            if item.isRecurringMaster {
                series.insert(item.id)
            } else if let master = item.recurringEventId {
                series.insert(master)
            } else if item.isCancelled {
                deleted.insert(item.id)
            } else if let instance = item.instance(account: calendar.account, calendarId: calendar.id) {
                upserts.append(instance)
            }
        }

        var replaced: [String: [EventInstance]] = [:]
        for id in series {
            replaced[id] = try await instances(of: id, in: calendar)
        }
        try cache.applyChanges(account: calendar.account, calendarId: calendar.id,
                               upserts: upserts, deletedIds: deleted, replacedSeries: replaced)
        var updated = calendar
        updated.syncToken = nextToken
        try cache.saveCalendar(updated)
        changed()
    }

    /// A series' instances in the calendar's window; empty when the series was deleted.
    private func instances(of seriesId: String, in calendar: CalendarInfo) async throws -> [EventInstance] {
        guard let from = calendar.windowStart, let to = calendar.windowEnd else { return [] }
        var result: [EventInstance] = []
        var page: String?
        do {
            repeat {
                let r = try await events(calendar, GoogleCalendarAPI.instancesRequest(
                    calendarId: calendar.id, eventId: seriesId, from: from, to: to, pageToken: page))
                result += (r.items ?? []).compactMap { $0.instance(account: calendar.account, calendarId: calendar.id) }
                page = r.nextPageToken
            } while page != nil
        } catch GoogleCalendarAPI.APIError.notFound {
            return []
        } catch GoogleCalendarAPI.APIError.syncTokenExpired {
            // 410 Gone on an instances request means the series was deleted
            return []
        }
        return result
    }

    private func events(_ calendar: CalendarInfo, _ build: @escaping GoogleCalendarAPI.Builder) async throws
        -> GoogleCalendarAPI.EventsPage {
        try await accounts.calendarAPI(GoogleCalendarAPI.EventsPage.self, for: calendar.account, build)
    }

    private func changed() {
        revision += 1
        onChange()
    }

    // MARK: Writes

    /// Shows or hides a calendar here and in Google Calendar (§12). The cache changes first, so the
    /// UI updates at once; a failed write puts it back.
    public func setSelected(_ selected: Bool, calendar: CalendarInfo) async throws {
        pendingSelected[calendar.key] = selected
        defer { pendingSelected[calendar.key] = nil }
        try cache.setSelected(selected, account: calendar.account, calendarId: calendar.id)
        changed()
        do {
            let (_, status) = try await accounts.sendAuthorized(
                for: calendar.account, GoogleCalendarAPI.setSelectedRequest(calendarId: calendar.id, selected: selected))
            try GoogleCalendarAPI.checkStatus(status)
        } catch {
            try cache.setSelected(calendar.selected, account: calendar.account, calendarId: calendar.id)
            changed()
            throw error
        }
    }
}
