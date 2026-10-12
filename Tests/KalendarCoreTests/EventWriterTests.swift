// EventWriter against a fake Google: optimistic cache updates, the queue, conflicts, offline,
// delete and undo, RSVP, moves.
import XCTest
@testable import KalendarCore

@MainActor
final class EventWriterTests: XCTestCase {
    private let google = FakeGoogle()
    private var cache: CalendarCache!
    private var engine: SyncEngine!
    private var writer: EventWriter!
    private let now = ISO8601DateFormatter().date(from: "2026-10-12T17:00:00Z")!
    private let start = ISO8601DateFormatter().date(from: "2026-10-12T16:00:00Z")!

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "EventWriterTests")!
        defaults.removePersistentDomain(forName: "EventWriterTests")
        defaults.set(["me@example.com"], forKey: "accounts")
        let google = self.google
        let accounts = AccountStore(defaults: defaults, vault: StubVault(), transport: { try await google($0) },
                                    now: { [now] in now })
        cache = try CalendarCache()
        engine = SyncEngine(accounts: accounts, cache: cache, now: { [now] in now })
        writer = EventWriter(accounts: accounts, cache: cache, engine: engine, now: { [now] in now })
        try cache.replaceCalendars([
            CalendarInfo(account: "me@example.com", id: "primary", summary: "Me", backgroundColor: "#000000",
                         accessRole: "owner", selected: true, primary: true),
            CalendarInfo(account: "me@example.com", id: "other", summary: "Other", backgroundColor: "#000000",
                         accessRole: "owner", selected: true, primary: false),
        ], account: "me@example.com")
    }

    private func event(id: String = "e1", attendees: [Attendee] = [], organizer: Bool = true,
                       series: String? = nil) -> EventInstance {
        EventInstance(account: "me@example.com", calendarId: "primary", id: id, recurringEventId: series,
                      summary: "Standup", location: nil, notes: nil, start: start, end: start.addingTimeInterval(1800),
                      allDay: false, transparency: nil, colorId: nil, conferenceURL: nil,
                      selfResponse: attendees.first(where: \.isSelf)?.responseStatus, organizerSelf: organizer,
                      attendees: attendees, htmlLink: nil, etag: "\"1\"", visibility: nil, reminders: Reminders(),
                      timeZone: "UTC")
    }

    private func serverEvent(_ id: String, title: String, etag: String = "\"2\"") -> String {
        #"{"id":"\#(id)","etag":"\#(etag.replacingOccurrences(of: "\"", with: "\\\""))","summary":"\#(title)","start":{"dateTime":"2026-10-12T16:00:00Z"},"end":{"dateTime":"2026-10-12T16:30:00Z"}}"#
    }

    private func cached(_ id: String = "e1") throws -> EventInstance? {
        try cache.event(account: "me@example.com", calendarId: "primary", id: id)
    }

    func testSaveUpdatesCacheThenTakesGooglesCopy() async throws {
        let e = event()
        try cache.upsert([e])
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.summary = "Standup (moved)"
        google.handler = { _, _ in (200, self.serverEvent("e1", title: "Standup (moved)")) }

        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil)
        XCTAssertEqual(try cached()?.summary, "Standup (moved)", "the cache changes before Google answers")
        await writer.flush()

        let patch = try XCTUnwrap(google.requests.first)
        XCTAssertEqual(patch.httpMethod, "PATCH")
        XCTAssertEqual(patch.url?.path, "/calendar/v3/calendars/primary/events/e1")
        XCTAssertEqual(patch.value(forHTTPHeaderField: "If-Match"), "\"1\"")
        XCTAssertEqual(patch.json?["summary"] as? String, "Standup (moved)")
        XCTAssertEqual(try cached()?.etag, "\"2\"")
        XCTAssertEqual(try cache.pendingWriteCount(), 0)
        XCTAssertNil(writer.error)
    }

    func testConflictRestoresGooglesVersionAndReports() async throws {
        let e = event()
        try cache.upsert([e])
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.summary = "Mine"
        google.handler = { r, _ in r.httpMethod == "PATCH" ? (412, "{}") : (200, self.serverEvent("e1", title: "Theirs", etag: "\"3\"")) }

        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil)
        await writer.flush()
        XCTAssertEqual(try cached()?.summary, "Theirs")
        XCTAssertEqual(writer.error, "“Mine” changed in Google Calendar, so your edit wasn't saved.")
        XCTAssertEqual(try cache.pendingWriteCount(), 0)
    }

    func testOfflineWriteWaitsInTheQueue() async throws {
        let e = event()
        try cache.upsert([e])
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.location = "Room 4"
        google.offline = true
        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil)
        await writer.flush()
        XCTAssertEqual(try cache.pendingWriteCount(), 1)
        XCTAssertEqual(try cached()?.location, "Room 4")
        XCTAssertNil(writer.error)

        google.offline = false
        google.handler = { _, _ in (200, self.serverEvent("e1", title: "Standup")) }
        await writer.flush()
        XCTAssertEqual(try cache.pendingWriteCount(), 0)
        XCTAssertEqual(google.requests.first?.json?["location"] as? String, "Room 4")
    }

    func testDeleteAndUndoRestoresTheEvent() async throws {
        let e = event()
        try cache.upsert([e])
        google.handler = { r, _ in
            r.httpMethod == "DELETE" ? (204, "") : (200, self.serverEvent("e1", title: "Standup"))
        }
        writer.delete(e, scope: .occurrence)
        XCTAssertNil(try cached())
        await writer.flush()
        XCTAssertNotNil(writer.undoableDelete)

        writer.undoDelete()
        XCTAssertNotNil(try cached(), "undo puts the event back at once")
        await writer.flush()
        let restore = try XCTUnwrap(google.requests.last)
        XCTAssertEqual(restore.httpMethod, "PATCH")
        XCTAssertEqual(restore.json?["status"] as? String, "confirmed")
        XCTAssertEqual(try cached()?.etag, "\"2\"")
        XCTAssertNil(writer.undoableDelete)
    }

    /// If Google won't un-cancel the event, undo inserts a copy without its guests (§8.2).
    func testUndoFallsBackToInsertingACopy() async throws {
        let e = event()
        try cache.upsert([e])
        google.handler = { r, _ in
            switch r.httpMethod {
            case "DELETE": (204, "")
            case "PATCH": (400, "{}")
            default: (200, self.serverEvent("copy1", title: "Standup"))
            }
        }
        writer.delete(e, scope: .occurrence)
        await writer.flush()
        writer.undoDelete()
        await writer.flush()
        let insert = try XCTUnwrap(google.requests.last)
        XCTAssertEqual(insert.httpMethod, "POST")
        XCTAssertEqual(insert.url?.path, "/calendar/v3/calendars/primary/events")
        XCTAssertEqual(insert.json?["summary"] as? String, "Standup")
        XCTAssertNil(writer.error)
        XCTAssertNotNil(try cached("copy1"))
    }

    func testInvitationDeleteCannotBeUndone() async throws {
        let me = Attendee(email: "me@example.com", displayName: nil, isSelf: true, organizer: false, optional: false, responseStatus: "accepted")
        let e = event(attendees: [me], organizer: false)
        try cache.upsert([e])
        writer.delete(e, scope: .occurrence)
        XCTAssertNil(writer.undoableDelete)
    }

    func testRSVPPatchesAttendeesAndNotifies() async throws {
        let me = Attendee(email: "me@example.com", displayName: nil, isSelf: true, organizer: false, optional: false, responseStatus: "needsAction")
        let alex = Attendee(email: "alex@example.com", displayName: nil, isSelf: false, organizer: true, optional: false, responseStatus: "accepted")
        let e = event(attendees: [me, alex], organizer: false)
        try cache.upsert([e])
        XCTAssertEqual(try cache.pendingInvitations(now: now).map(\.id), ["e1"])
        google.handler = { _, _ in (200, self.serverEvent("e1", title: "Standup")) }

        writer.respond(e, response: "accepted", scope: .occurrence)
        XCTAssertEqual(try cached()?.selfResponse, "accepted")
        XCTAssertTrue(try cache.pendingInvitations(now: now).isEmpty)
        await writer.flush()
        let patch = try XCTUnwrap(google.requests.first)
        XCTAssertEqual(URLComponents(url: patch.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "sendUpdates" }?.value, "all")
        XCTAssertEqual((patch.json?["attendees"] as? [[String: Any]])?.map { $0["responseStatus"] as? String },
                       ["accepted", "accepted"])
    }

    func testSeriesDeleteTargetsTheMaster() async throws {
        let e = event(id: "w_20261012", series: "w")
        try cache.upsert([e, event(id: "w_20261019", series: "w")])
        google.handler = { _, _ in (204, "") }
        writer.delete(e, scope: .series)
        XCTAssertNil(try cached("w_20261019"), "every cached occurrence goes")
        await writer.flush()
        XCTAssertEqual(google.requests.first?.url?.path, "/calendar/v3/calendars/primary/events/w")
    }

    func testMoveToAnotherCalendarUsesEventsMove() async throws {
        let e = event()
        try cache.upsert([e])
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.calendarId = "other"
        google.handler = { _, _ in (200, self.serverEvent("e1", title: "Standup")) }
        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil)
        XCTAssertNotNil(try cache.event(account: "me@example.com", calendarId: "other", id: "e1"))
        await writer.flush()
        let move = try XCTUnwrap(google.requests.first)
        XCTAssertEqual(move.url?.path, "/calendar/v3/calendars/primary/events/e1/move")
        XCTAssertEqual(URLComponents(url: move.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "destination" }?.value, "other")
        XCTAssertNil(try cached())
        XCTAssertNotNil(try cache.event(account: "me@example.com", calendarId: "other", id: "e1"))
    }

    func testRejectedWriteReportsAndRefetches() async throws {
        let e = event()
        try cache.upsert([e])
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.summary = "Nope"
        google.handler = { r, _ in r.httpMethod == "PATCH" ? (403, "{}") : (200, self.serverEvent("e1", title: "Standup")) }
        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil)
        await writer.flush()
        XCTAssertEqual(writer.error, "Couldn't save “Nope”: Google returned an error (HTTP 403).")
        XCTAssertEqual(try cached()?.summary, "Standup")
    }
}
