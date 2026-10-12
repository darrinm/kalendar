// Keeps the cache in step with Google Calendar (§18.3).
//
// Per calendar:
// - First sync: page through every event, ids only, to get a sync token for the change stream;
//   then fetch expanded instances for the window (today −1 year … +1 year).
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
    /// When the last sync finished, successfully or not.
    public private(set) var lastSync: Date?
    /// Called on the main actor whenever the cache changed: once per account sync that wrote
    /// something, and after visibility changes and account removal.
    @ObservationIgnored public var onChange: () -> Void = {}

    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let cache: CalendarCache
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var pending = false
    /// Set by any cache write during the current account's sync.
    @ObservationIgnored private var wrote = false
    /// Calendar-list fetches started so far; orders visibility writes against fetches.
    @ObservationIgnored private var listFetches = 0
    /// Visibility writes not yet reflected in a fetched calendar list, by calendar key.
    /// `landedAt` is `listFetches` when Google accepted the write: a list fetch started after that
    /// includes the write, so the overlay can go.
    @ObservationIgnored private var pendingSelected: [String: (selected: Bool, landedAt: Int?)] = [:]

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

    /// Periodic and on-open syncs: skipped while a sync runs or when the last one is recent.
    public func syncIfNeeded(maxAge: TimeInterval) async {
        if running != nil { return }
        if let lastSync, now().timeIntervalSince(lastSync) < maxAge { return }
        await syncAll()
    }

    /// Sign-out (§8.5): deletes everything cached for the account.
    public func removeAccount(_ email: String) {
        do { try cache.deleteAccount(email) } catch {
            Log.sync.error("deleting cached data failed: \(error.localizedDescription)")
        }
        onChange()
    }

    private func runAll() async {
        state = .syncing
        var failure: String?
        for account in accounts.accounts where !account.needsReauth {
            wrote = false
            do {
                try await sync(account: account.email)
            } catch {
                Log.sync.error("sync \(account.email, privacy: .private) failed: \(error.localizedDescription)")
                failure = error.localizedDescription
            }
            // signed out while this account synced: drop what the sync wrote after sign-out deleted it
            if !accounts.accounts.contains(where: { $0.email == account.email }) {
                removeAccount(account.email)
            } else if wrote {
                onChange()
            }
        }
        state = failure.map(State.failed) ?? .idle
        lastSync = now()
    }

    func sync(account: String) async throws {
        listFetches += 1
        let fetch = listFetches
        var listed = try await pages(GoogleCalendarAPI.CalendarListPage.self, for: account) {
            GoogleCalendarAPI.calendarListRequest(pageToken: $0)
        }.flatMap { $0.calendars(account: account) }
        for i in listed.indices {
            if let overlay = pendingSelected[listed[i].key] { listed[i].selected = overlay.selected }
        }
        if try cache.replaceCalendars(listed, account: account) { wrote = true }
        pendingSelected = pendingSelected.filter { _, value in value.landedAt.map { $0 >= fetch } ?? true }

        if try !cache.hasEventColors(account: account) {
            let colors = try await accounts.calendarAPI(GoogleCalendarAPI.ColorsResponse.self, for: account,
                                                        GoogleCalendarAPI.colorsRequest())
            try cache.replaceEventColors(colors.colors(account: account), account: account)
            wrote = true
        }

        // calendars sync concurrently, so their requests overlap; a free/busy-only calendar returns
        // no event details, so there is nothing to show for it
        let calendars = try cache.calendars(account: account).filter { $0.accessRole != "freeBusyReader" }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for calendar in calendars {
                group.addTask { try await self.sync(calendar: calendar) }
            }
            try await group.waitForAll()
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
        let token = try await eventPages(calendar) {
            GoogleCalendarAPI.tokenPassRequest(calendarId: calendar.id, pageToken: $0)
        }.compactMap(\.nextSyncToken).last
        let instances = try await eventPages(calendar) {
            GoogleCalendarAPI.windowRequest(calendarId: calendar.id, from: from, to: to, pageToken: $0)
        }.flatMap { parsed($0, calendar: calendar) }

        try cache.replaceEvents(instances, account: calendar.account, calendarId: calendar.id)
        var updated = calendar
        updated.syncToken = token
        updated.windowStart = from
        updated.windowEnd = to
        try cache.saveCalendar(updated)
        wrote = true
    }

    private func incrementalSync(_ calendar: CalendarInfo, token: String) async throws {
        let pages = try await eventPages(calendar) {
            GoogleCalendarAPI.changesRequest(calendarId: calendar.id, syncToken: token, pageToken: $0)
        }
        let items = pages.flatMap { $0.items ?? [] }
        let nextToken = pages.compactMap(\.nextSyncToken).last ?? token
        if items.isEmpty && nextToken == token { return }

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
        if !items.isEmpty {
            try cache.applyChanges(account: calendar.account, calendarId: calendar.id,
                                   upserts: upserts, deletedIds: deleted, replacedSeries: replaced)
            wrote = true
        }
        var updated = calendar
        updated.syncToken = nextToken
        try cache.saveCalendar(updated)
    }

    /// A series' instances in the calendar's window; empty when the series was deleted.
    private func instances(of seriesId: String, in calendar: CalendarInfo) async throws -> [EventInstance] {
        guard let from = calendar.windowStart, let to = calendar.windowEnd else { return [] }
        do {
            return try await eventPages(calendar) {
                GoogleCalendarAPI.instancesRequest(calendarId: calendar.id, eventId: seriesId, from: from, to: to, pageToken: $0)
            }.flatMap { parsed($0, calendar: calendar) }
        } catch let error as GoogleCalendarAPI.APIError where error == .notFound || error == .syncTokenExpired {
            // 404 or 410 Gone on an instances request means the series was deleted
            return []
        }
    }

    private func parsed(_ page: GoogleCalendarAPI.EventsPage, calendar: CalendarInfo) -> [EventInstance] {
        (page.items ?? []).compactMap { $0.instance(account: calendar.account, calendarId: calendar.id) }
    }

    /// Every page of a paged list, following `nextPageToken`.
    private func pages<Page: GoogleCalendarAPI.Paged>(_ type: Page.Type, for account: String,
                                                    _ build: (String?) -> GoogleCalendarAPI.Builder) async throws -> [Page] {
        var result: [Page] = []
        var token: String?
        repeat {
            let page = try await accounts.calendarAPI(Page.self, for: account, build(token))
            result.append(page)
            token = page.nextPageToken
        } while token != nil
        return result
    }

    private func eventPages(_ calendar: CalendarInfo,
                            _ build: (String?) -> GoogleCalendarAPI.Builder) async throws -> [GoogleCalendarAPI.EventsPage] {
        try await pages(GoogleCalendarAPI.EventsPage.self, for: calendar.account, build)
    }

    // MARK: Writes

    /// Shows or hides a calendar here and in Google Calendar (§12). The cache changes first, so the
    /// UI updates at once; a failed write puts it back.
    public func setSelected(_ selected: Bool, calendar: CalendarInfo) async throws {
        pendingSelected[calendar.key] = (selected, nil)
        try cache.setSelected(selected, account: calendar.account, calendarId: calendar.id)
        onChange()
        do {
            let (_, status) = try await accounts.sendAuthorized(
                for: calendar.account, GoogleCalendarAPI.setSelectedRequest(calendarId: calendar.id, selected: selected))
            try GoogleCalendarAPI.checkStatus(status)
            pendingSelected[calendar.key]?.landedAt = listFetches
        } catch {
            pendingSelected[calendar.key] = nil
            try cache.setSelected(calendar.selected, account: calendar.account, calendarId: calendar.id)
            onChange()
            throw error
        }
    }
}
