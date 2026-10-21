// SyncEngine and CalendarCache against a fake Google that routes requests by URL.
import XCTest
@testable import KalendarCore

@MainActor
final class SyncEngineTests: XCTestCase {
    private let google = FakeGoogle()
    private var cache: CalendarCache!
    private var engine: SyncEngine!
    private let now = ISO8601DateFormatter().date(from: "2026-10-12T17:00:00Z")!

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "SyncEngineTests")!
        defaults.removePersistentDomain(forName: "SyncEngineTests")
        defaults.set(["me@example.com"], forKey: "accounts")
        let google = self.google
        let accounts = AccountStore(defaults: defaults, vault: StubVault(), transport: { try await google($0) },
                                    now: { [now] in now })
        cache = try CalendarCache()
        engine = SyncEngine(accounts: accounts, cache: cache, now: { [now] in now })
    }

    private static func timed(_ id: String, _ title: String, start: String, end: String,
                              recurringEventId: String? = nil, status: String = "confirmed") -> String {
        let series = recurringEventId.map { #","recurringEventId":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","status":"\#(status)","summary":"\#(title)","start":{"dateTime":"\#(start)"},"end":{"dateTime":"\#(end)"}\#(series)}"#
    }

    /// The first sync of a calendar: list, colors, window instances, ids-only token pass.
    private func serveFirstSync(events: [String], token: String = "t1") {
        google.handler = { request, q in
            switch request.url!.path {
            case "/calendar/v3/users/me/calendarList":
                return (200, ##"{"items":[{"id":"primary@example.com","summary":"Me","backgroundColor":"#7986cb","accessRole":"owner","selected":true,"primary":true},{"id":"hidden@example.com","summary":"Hidden","accessRole":"reader","selected":false}]}"##)
            case "/calendar/v3/colors":
                return (200, ##"{"event":{"1":{"background":"#a4bdfc"},"11":{"background":"#dc2127"}}}"##)
            case let p where p.hasSuffix("/events") && q["singleEvents"] == "true":
                return (200, #"{"items":[\#(p.contains("primary") ? events.joined(separator: ",") : "")]}"#)
            case let p where p.hasSuffix("/events") && q["singleEvents"] == "false":
                return (200, #"{"items":[{"id":"x"}],"nextSyncToken":"\#(token)"}"#)
            default:
                return (404, "{}")
            }
        }
    }

    func testFirstSyncFillsTheCache() async throws {
        serveFirstSync(events: [Self.timed("a", "Standup", start: "2026-10-12T16:00:00Z", end: "2026-10-12T16:15:00Z")])
        await engine.syncAll()
        XCTAssertEqual(engine.state, .idle)

        let calendars = try cache.calendars()
        XCTAssertEqual(calendars.map(\.id).sorted(), ["hidden@example.com", "primary@example.com"])
        let primary = try XCTUnwrap(calendars.first { $0.primary })
        XCTAssertEqual(primary.syncToken, "t1")
        XCTAssertEqual(primary.windowStart, Calendar.current.startOfDay(for: now).addingTimeInterval(-365 * 86400))
        XCTAssertEqual(try cache.eventColors()["me@example.com"]?["11"], "#dc2127")

        let day = try cache.events(from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(86400))
        XCTAssertEqual(day.map(\.summary), ["Standup"])
    }

    func testHiddenCalendarsAreSyncedButNotShown() async throws {
        serveFirstSync(events: [])
        let base = google.handler
        google.handler = { request, q in
            if request.url!.path.contains("hidden"), q["singleEvents"] == "true" {
                return (200, #"{"items":[\#(Self.timed("h", "Hidden thing", start: "2026-10-12T16:00:00Z", end: "2026-10-12T17:00:00Z"))]}"#)
            }
            return base(request, q)
        }
        await engine.syncAll()
        XCTAssertTrue(try cache.events(from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(86400)).isEmpty)
        XCTAssertEqual(try cache.search("Hidden", scope: .title).count, 0)
    }

    func testIncrementalSyncAppliesSingleChangesAndRefetchesSeries() async throws {
        serveFirstSync(events: [
            Self.timed("a", "Standup", start: "2026-10-12T16:00:00Z", end: "2026-10-12T16:15:00Z"),
            Self.timed("gone", "Cancelled later", start: "2026-10-12T18:00:00Z", end: "2026-10-12T19:00:00Z"),
            Self.timed("w_1", "Weekly", start: "2026-10-12T20:00:00Z", end: "2026-10-12T21:00:00Z", recurringEventId: "w"),
            Self.timed("w_2", "Weekly", start: "2026-10-19T20:00:00Z", end: "2026-10-19T21:00:00Z", recurringEventId: "w"),
        ])
        await engine.syncAll()

        let first = google.handler
        google.handler = { request, q in
            let path = request.url!.path
            if path.contains("primary"), q["syncToken"] == "t1" {
                return (200, #"{"items":[\#(Self.timed("a", "Standup (moved)", start: "2026-10-12T16:30:00Z", end: "2026-10-12T16:45:00Z")),{"id":"gone","status":"cancelled"},{"id":"w","recurrence":["RRULE:FREQ=WEEKLY"],"start":{"dateTime":"2026-10-12T21:00:00Z"},"end":{"dateTime":"2026-10-12T22:00:00Z"}}],"nextSyncToken":"t2"}"#)
            }
            if path.hasSuffix("/events/w/instances") {
                return (200, #"{"items":[\#(Self.timed("w_1", "Weekly", start: "2026-10-12T21:00:00Z", end: "2026-10-12T22:00:00Z", recurringEventId: "w"))]}"#)
            }
            if q["syncToken"] != nil { return (200, #"{"items":[],"nextSyncToken":"t1"}"#) }
            return first(request, q)
        }
        google.log.removeAll()
        await engine.syncAll()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertFalse(google.log.contains { $0.contains("single=true") }, "incremental sync must not refetch the window")

        let week = try cache.events(from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(8 * 86400))
        XCTAssertEqual(week.map(\.summary), ["Standup (moved)", "Weekly"])
        XCTAssertEqual(week.last?.start, ISO8601DateFormatter().date(from: "2026-10-12T21:00:00Z"))
        XCTAssertEqual(try cache.calendars().first { $0.primary }?.syncToken, "t2")
    }

    func testExpiredTokenTriggersFullResync() async throws {
        serveFirstSync(events: [Self.timed("a", "Old", start: "2026-10-12T16:00:00Z", end: "2026-10-12T17:00:00Z")])
        await engine.syncAll()

        serveFirstSync(events: [Self.timed("b", "New", start: "2026-10-12T16:00:00Z", end: "2026-10-12T17:00:00Z")], token: "t9")
        let resync = google.handler
        google.handler = { request, q in q["syncToken"] != nil ? (410, "{}") : resync(request, q) }
        await engine.syncAll()

        let day = try cache.events(from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(86400))
        XCTAssertEqual(day.map(\.summary), ["New"])
        XCTAssertEqual(try cache.calendars().first { $0.primary }?.syncToken, "t9")
    }

    func testCalendarRemovedFromGoogleIsDropped() async throws {
        serveFirstSync(events: [Self.timed("a", "Standup", start: "2026-10-12T16:00:00Z", end: "2026-10-12T16:15:00Z")])
        await engine.syncAll()
        google.handler = { request, q in
            if request.url!.path.hasSuffix("calendarList") { return (200, #"{"items":[]}"#) }
            return (200, #"{"items":[],"nextSyncToken":"t1"}"#)
        }
        await engine.syncAll()
        XCTAssertTrue(try cache.calendars().isEmpty)
        XCTAssertTrue(try cache.search("Standup", scope: .all).isEmpty)
    }

    func testFailureLeavesCacheAndReportsState() async throws {
        serveFirstSync(events: [Self.timed("a", "Standup", start: "2026-10-12T16:00:00Z", end: "2026-10-12T16:15:00Z")])
        await engine.syncAll()
        google.handler = { _, _ in (503, "{}") }
        await engine.syncAll()
        XCTAssertEqual(engine.state, .failed(GoogleCalendarAPI.APIError.http(503).localizedDescription))
        XCTAssertEqual(try cache.search("Standup", scope: .title).count, 1)
    }

    func testSearchScopes() async throws {
        serveFirstSync(events: [
            #"{"id":"a","summary":"Lunch","location":"Tartine","description":"bring notes","start":{"dateTime":"2026-10-12T19:00:00Z"},"end":{"dateTime":"2026-10-12T20:00:00Z"},"attendees":[{"email":"sam@example.com","displayName":"Sam Lee"}]}"#,
        ])
        await engine.syncAll()
        XCTAssertEqual(try cache.search("lunch", scope: .title).count, 1)
        XCTAssertEqual(try cache.search("tartine", scope: .title).count, 0)
        XCTAssertEqual(try cache.search("tartine", scope: .location).count, 1)
        XCTAssertEqual(try cache.search("Sam Lee", scope: .invitees).count, 1)
        XCTAssertEqual(try cache.search("notes", scope: .all).count, 1)
        XCTAssertEqual(try cache.search("%", scope: .all).count, 0)
        XCTAssertEqual(try cache.search("\\", scope: .all).count, 0)
        // the attendees column is JSON; its keys must not match
        XCTAssertEqual(try cache.search("displayName", scope: .invitees).count, 0)
        XCTAssertEqual(try cache.search("sam@", scope: .invitees).count, 1)
    }

    func testDeletedSeriesRemovesItsInstances() async throws {
        serveFirstSync(events: [
            Self.timed("w_1", "Weekly", start: "2026-10-12T20:00:00Z", end: "2026-10-12T21:00:00Z", recurringEventId: "w"),
            Self.timed("w_2", "Weekly", start: "2026-10-19T20:00:00Z", end: "2026-10-19T21:00:00Z", recurringEventId: "w"),
        ])
        await engine.syncAll()
        // Google reports a deleted series as its master's id and status only
        let first = google.handler
        google.handler = { request, q in
            guard let token = q["syncToken"] else { return first(request, q) }
            return request.url!.path.contains("primary") && token == "t1"
                ? (200, #"{"items":[{"id":"w","status":"cancelled"}],"nextSyncToken":"t2"}"#)
                : (200, #"{"items":[],"nextSyncToken":"t2"}"#)
        }
        await engine.syncAll()
        XCTAssertTrue(try cache.search("Weekly", scope: .title).isEmpty)
    }

    /// Invited to some occurrences of a series only: the calendar has no master, so the instances
    /// request answers 404. The changed occurrence is applied on its own and the other one stays.
    func testChangedOccurrenceWithoutAMasterIsKept() async throws {
        serveFirstSync(events: [
            Self.timed("w_1", "Weekly", start: "2026-10-12T20:00:00Z", end: "2026-10-12T21:00:00Z", recurringEventId: "w"),
            Self.timed("w_2", "Weekly", start: "2026-10-19T20:00:00Z", end: "2026-10-19T21:00:00Z", recurringEventId: "w"),
        ])
        await engine.syncAll()
        let first = google.handler
        google.handler = { request, q in
            guard let token = q["syncToken"] else { return first(request, q) }
            return request.url!.path.contains("primary") && token == "t1"
                ? (200, #"{"items":[\#(Self.timed("w_1", "Weekly (moved)", start: "2026-10-12T21:00:00Z", end: "2026-10-12T22:00:00Z", recurringEventId: "w"))],"nextSyncToken":"t2"}"#)
                : (200, #"{"items":[],"nextSyncToken":"t2"}"#)
        }
        await engine.syncAll()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertTrue(google.log.contains { $0.hasSuffix("/events/w/instances") })
        let week = try cache.events(from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(8 * 86400))
        XCTAssertEqual(week.map(\.summary), ["Weekly (moved)", "Weekly"])
    }

    func testSetSelectedWritesGoogleAndRevertsOnFailure() async throws {
        serveFirstSync(events: [])
        await engine.syncAll()
        let primary = try XCTUnwrap(try cache.calendars().first { $0.primary })

        google.handler = { request, _ in request.httpMethod == "PATCH" ? (200, #"{"id":"x","selected":false}"#) : (404, "{}") }
        try await engine.setSelected(false, calendar: primary)
        XCTAssertEqual(try cache.calendars().first { $0.primary }?.selected, false)
        XCTAssertEqual(try cache.calendars().first { $0.primary }?.syncToken, "t1")
        XCTAssertTrue(google.log.last!.hasPrefix("PATCH /calendar/v3/users/me/calendarList/primary@example.com"))

        let hidden = try XCTUnwrap(try cache.calendars().first { $0.primary })
        google.handler = { _, _ in (500, "{}") }
        do {
            try await engine.setSelected(true, calendar: hidden)
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(try cache.calendars().first { $0.primary }?.selected, false)
    }

    /// A sync that lists calendars while a visibility write is in flight keeps the new value.
    func testSyncDuringVisibilityWriteKeepsTheNewValue() async throws {
        serveFirstSync(events: [])
        await engine.syncAll()
        let primary = try XCTUnwrap(try cache.calendars().first { $0.primary })

        let listing = google.handler
        google.handler = { request, q in
            if request.httpMethod == "PATCH" { return (200, #"{"id":"x","selected":false}"#) }
            if q["syncToken"] != nil { return (200, #"{"items":[],"nextSyncToken":"t1"}"#) }
            return listing(request, q)   // the calendar list still says selected: true
        }
        google.patchDelay = 200_000_000
        let write = Task { try await engine.setSelected(false, calendar: primary) }
        await engine.syncAll()
        try await write.value
        XCTAssertEqual(try cache.calendars().first { $0.primary }?.selected, false)
    }

    func testDeleteAccountClearsEverything() async throws {
        serveFirstSync(events: [Self.timed("a", "Standup", start: "2026-10-12T16:00:00Z", end: "2026-10-12T16:15:00Z")])
        await engine.syncAll()
        try cache.deleteAccount("me@example.com")
        XCTAssertTrue(try cache.calendars().isEmpty)
        XCTAssertTrue(try cache.eventColors().isEmpty)
        XCTAssertTrue(try cache.search("Standup", scope: .all).isEmpty)
    }
}
