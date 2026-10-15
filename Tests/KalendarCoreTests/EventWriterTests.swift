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
        defaults.set(["me@example.com", "work@example.com"], forKey: "accounts")
        let google = self.google
        let accounts = AccountStore(defaults: defaults, vault: StubVault(), transport: { try await google($0) },
                                    now: { [now] in now })
        cache = try CalendarCache()
        engine = SyncEngine(accounts: accounts, cache: cache, now: { [now] in now })
        writer = EventWriter(accounts: accounts, cache: cache, engine: engine, now: { [now] in now }, conferencePoll: 0)
        try cache.replaceCalendars([
            CalendarInfo(account: "me@example.com", id: "primary", summary: "Me", backgroundColor: "#000000",
                         accessRole: "owner", selected: true, primary: true),
            CalendarInfo(account: "me@example.com", id: "other", summary: "Other", backgroundColor: "#000000",
                         accessRole: "owner", selected: true, primary: false),
        ], account: "me@example.com")
        try cache.replaceCalendars([
            CalendarInfo(account: "work@example.com", id: "work", summary: "Work", backgroundColor: "#000000",
                         accessRole: "owner", selected: true, primary: true),
        ], account: "work@example.com")
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

    /// A calendar both accounts cache (one subscribes to the other's): deleting the event through
    /// one account removes the other account's copy too, instead of leaving it until its next sync.
    func testDeleteRemovesEveryAccountsCopy() async throws {
        let e = event()
        var shared = e
        shared.account = "work@example.com"
        try cache.upsert([e, shared])
        google.handler = { _, _ in (204, "") }
        writer.delete(e, scope: .occurrence)
        XCTAssertNil(try cached())
        XCTAssertNil(try cache.event(account: "work@example.com", calendarId: "primary", id: "e1"))
    }

    /// An edit in place reaches every account's copy of the event, so the other account's doesn't
    /// show the old version (or vanish) until its sync; it keeps its own response and alerts.
    func testEditUpdatesOtherAccountsCopy() async throws {
        try cache.replaceCalendars([
            CalendarInfo(account: "work@example.com", id: "work", summary: "Work", backgroundColor: "#000000",
                         accessRole: "owner", selected: true, primary: true),
            CalendarInfo(account: "work@example.com", id: "primary", summary: "Me", backgroundColor: "#000000",
                         accessRole: "reader", selected: true, primary: false),
        ], account: "work@example.com")
        let e = event()
        var shared = e
        shared.account = "work@example.com"
        shared.selfResponse = "tentative"
        shared.reminders = Reminders(useDefault: false, minutes: [30])
        try cache.upsert([e, shared])
        google.handler = { _, _ in (200, self.serverEvent("e1", title: "Standup (moved)")) }
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.summary = "Standup (moved)"
        draft.start = start.addingTimeInterval(3600)
        draft.end = draft.start.addingTimeInterval(1800)
        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil)
        XCTAssertEqual(try cached()?.summary, "Standup (moved)")
        let copy = try XCTUnwrap(cache.event(account: "work@example.com", calendarId: "primary", id: "e1"))
        XCTAssertEqual(copy.summary, "Standup (moved)")
        XCTAssertEqual(copy.start, draft.start)
        XCTAssertEqual(copy.selfResponse, "tentative")
        XCTAssertEqual(copy.reminders.minutes, [30])
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

    /// Another account: insert a copy there, delete the original; the placeholder cached under the
    /// old id gives way to Google's copy under its new id.
    func testMoveToAnotherAccountLeavesOneCopy() async throws {
        let e = event()
        try cache.upsert([e])
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.account = "work@example.com"
        draft.calendarId = "work"
        google.handler = { r, _ in r.httpMethod == "DELETE" ? (204, "") : (200, self.serverEvent("new1", title: "Standup")) }
        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil)
        await writer.flush()
        XCTAssertEqual(google.requests.map { "\($0.httpMethod!) \($0.url!.path)" },
                       ["POST /calendar/v3/calendars/work/events", "DELETE /calendar/v3/calendars/primary/events/e1"])
        XCTAssertNil(try cached())
        XCTAssertNil(try cache.event(account: "work@example.com", calendarId: "work", id: "e1"))
        XCTAssertNotNil(try cache.event(account: "work@example.com", calendarId: "work", id: "new1"))
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

    /// The optimistic delete removed both accounts' copies of a shared calendar's event. Google
    /// rejects it, so the event is unchanged and no incremental sync would return it: both
    /// accounts refetch their copy.
    func testRejectedDeleteRestoresEveryAccountsCopy() async throws {
        try cache.replaceCalendars([
            CalendarInfo(account: "work@example.com", id: "work", summary: "Work", backgroundColor: "#000000",
                         accessRole: "owner", selected: true, primary: true),
            CalendarInfo(account: "work@example.com", id: "primary", summary: "Me", backgroundColor: "#000000",
                         accessRole: "reader", selected: true, primary: false),
        ], account: "work@example.com")
        let e = event()
        var shared = e
        shared.account = "work@example.com"
        try cache.upsert([e, shared])
        google.handler = { r, _ in r.httpMethod == "DELETE" ? (403, "{}") : (200, self.serverEvent("e1", title: "Standup")) }
        writer.delete(e, scope: .occurrence)
        await writer.flush()
        XCTAssertNotNil(try cached())
        XCTAssertNotNil(try cache.event(account: "work@example.com", calendarId: "primary", id: "e1"))
    }

    func testServerErrorKeepsTheWriteQueued() async throws {
        let e = event()
        try cache.upsert([e])
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.summary = "Later"
        google.handler = { _, _ in (503, "{}") }
        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil)
        await writer.flush()
        XCTAssertEqual(try cache.pendingWriteCount(), 1)
        XCTAssertNil(writer.error)
        XCTAssertEqual(try cached()?.summary, "Later")
    }

    /// A second edit queued behind the first is sent with the etag the first one produced.
    func testQueuedEditsCarryTheNewEtag() async throws {
        let e = event()
        try cache.upsert([e])
        let original = EventDraft(e, recurrence: nil)
        var first = original
        first.summary = "One"
        var second = first
        second.location = "Room 4"
        google.offline = true
        writer.save(e, original: original, draft: first, scope: .occurrence, series: nil)
        writer.save(e.applying(first), original: first, draft: second, scope: .occurrence, series: nil)
        await writer.flush()
        google.offline = false
        google.handler = { r, _ in
            let etag = r.value(forHTTPHeaderField: "If-Match")
            return etag == "\"1\"" && self.google.requests.count == 1 ? (200, self.serverEvent("e1", title: "One"))
                : etag == "\"2\"" ? (200, self.serverEvent("e1", title: "One", etag: "\"3\"")) : (412, "{}")
        }
        await writer.flush()
        XCTAssertEqual(google.requests.map { $0.value(forHTTPHeaderField: "If-Match") }, ["\"1\"", "\"2\""])
        XCTAssertNil(writer.error)
    }

    /// When a write is rejected, later writes about the same event are dropped with it.
    func testRejectedWriteDropsLaterWritesToTheEvent() async throws {
        let e = event()
        try cache.upsert([e])
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.summary = "Nope"
        google.offline = true
        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil)
        writer.delete(e, scope: .occurrence)
        await writer.flush()
        XCTAssertEqual(try cache.pendingWriteCount(), 2)
        google.offline = false
        google.handler = { r, _ in r.httpMethod == "PATCH" ? (403, "{}") : (200, self.serverEvent("e1", title: "Standup")) }
        await writer.flush()
        XCTAssertEqual(google.requests.compactMap(\.httpMethod), ["PATCH", "GET"])
        XCTAssertEqual(try cache.pendingWriteCount(), 0)
    }

    func testInsertShowsAPlaceholderUntilGooglesCopyArrives() async throws {
        let p = NLParser(now: now).parse("Coffee tomorrow 3pm")
        let draft = EventDraft(parsed: p, account: "me@example.com", calendarId: "primary")
        google.handler = { _, _ in (200, self.serverEvent("g1", title: "Coffee")) }
        writer.insert(draft)
        let placeholders = try cache.events(from: now, to: now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(placeholders.map(\.summary), ["Coffee"])
        XCTAssertTrue(placeholders[0].id.hasPrefix("local-"))
        await writer.flush()
        let after = try cache.events(from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(after.map(\.id), ["g1"], "Google's copy replaces the placeholder")
        let post = try XCTUnwrap(google.requests.first)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.json?["summary"] as? String, "Coffee")
        XCTAssertEqual((post.json?["reminders"] as? [String: Any])?["useDefault"] as? Bool, true)
    }

    func testGoogleMeetIsRequestedWithConferenceDataVersion() async throws {
        var draft = EventDraft(parsed: NLParser(now: now).parse("Sync tomorrow 3pm"), account: "me@example.com",
                               calendarId: "primary")
        google.handler = { _, _ in (200, self.serverEvent("g1", title: "Sync")) }
        writer.insert(draft)
        draft.addGoogleMeet = true
        writer.insert(draft)
        await writer.flush()
        let (plain, meet) = (google.requests[0], google.requests[1])
        XCTAssertNil(plain.json?["conferenceData"])
        XCTAssertFalse(plain.url!.query!.contains("conferenceDataVersion"))
        let create = try XCTUnwrap((meet.json?["conferenceData"] as? [String: Any])?["createRequest"] as? [String: Any])
        XCTAssertEqual((create["conferenceSolutionKey"] as? [String: String])?["type"], "hangoutsMeet")
        XCTAssertNotNil(create["requestId"] as? String)
        XCTAssertTrue(meet.url!.query!.contains("conferenceDataVersion=1"))
    }

    /// Google changes the event's etag about a second after answering an insert that creates a
    /// conference; the writer polls until it has.
    func testEditAfterAddingMeetSendsTheEtagFetchedAfterTheInsert() async throws {
        var draft = EventDraft(parsed: NLParser(now: now).parse("Sync tomorrow 3pm"), account: "me@example.com",
                               calendarId: "primary")
        draft.addGoogleMeet = true
        // the first fetch still has the insert's etag; Google's update arrives before the second
        google.handler = { r, _ in
            let gets = self.google.requests.filter { $0.httpMethod == "GET" }.count
            return (200, self.serverEvent("g1", title: "Sync", etag: r.httpMethod == "GET" && gets >= 2 ? "\"2\"" : "\"1\""))
        }
        writer.insert(draft)
        await writer.flush()
        XCTAssertEqual(google.requests.compactMap(\.httpMethod), ["POST", "GET", "GET"])
        let cached = try XCTUnwrap(cache.event(account: "me@example.com", calendarId: "primary", id: "g1"))
        XCTAssertEqual(cached.etag, "\"2\"")
        var edited = EventDraft(cached, recurrence: nil)
        edited.summary = "Sync (moved)"
        writer.save(cached, original: EventDraft(cached, recurrence: nil), draft: edited, scope: .occurrence, series: nil)
        await writer.flush()
        XCTAssertEqual(google.requests.last?.value(forHTTPHeaderField: "If-Match"), "\"2\"")
        XCTAssertNil(writer.error)
    }

    /// "Don't Send" (§8.6): no email for a change or a delete of an event the user organizes with guests.
    func testDontSendWritesWithoutEmailingGuests() async throws {
        let guests = [Attendee(email: "me@example.com", displayName: nil, isSelf: true, organizer: true, optional: false,
                               responseStatus: "accepted"),
                      Attendee(email: "kate@example.com", displayName: nil, isSelf: false, organizer: false, optional: false,
                               responseStatus: "accepted")]
        let e = event(attendees: guests)
        try cache.upsert([e])
        google.handler = { r, _ in r.httpMethod == "DELETE" ? (204, "") : (200, self.serverEvent("e1", title: "Standup")) }
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.start = start.addingTimeInterval(3600)
        draft.end = draft.start.addingTimeInterval(1800)
        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil, notifyGuests: true)
        await writer.flush()
        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil, notifyGuests: false)
        await writer.flush()
        writer.delete(e, scope: .occurrence, notifyGuests: false)
        await writer.flush()
        XCTAssertEqual(google.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "sendUpdates" }!.value! }, ["all", "none", "none"])
    }

    /// Guests added to an event that had none are invited (§8.6).
    func testAddedGuestsAreInvited() async throws {
        let e = event()
        try cache.upsert([e])
        google.handler = { _, _ in (200, self.serverEvent("e1", title: "Standup")) }
        let original = EventDraft(e, recurrence: nil)
        var draft = original
        draft.attendees = [Attendee(email: "me@example.com", displayName: nil, isSelf: true, organizer: true, optional: false,
                                    responseStatus: "accepted"),
                           Attendee(email: "kate@example.com", displayName: nil, isSelf: false, organizer: false,
                                    optional: false, responseStatus: "needsAction")]
        XCTAssertFalse(EventWriter.emailsGuests(e))
        XCTAssertTrue(EventWriter.emailsGuests(e, editedTo: draft))
        writer.save(e, original: original, draft: draft, scope: .occurrence, series: nil)
        await writer.flush()
        XCTAssertEqual(google.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "sendUpdates" }!.value! }, ["all"])
    }

    /// Alerts, color and busy/free are the user's own; guests hear only about the rest.
    func testOnlySharedFieldsAreChangesGuestsSee() {
        let original = EventDraft(event(), recurrence: nil)
        var personal = original
        personal.reminders = Reminders(useDefault: false, minutes: [5])
        personal.colorId = "3"
        personal.busy = false
        XCTAssertFalse(personal.changesWhatGuestsSee(from: original))
        var shared = personal
        shared.location = "Room 4"
        XCTAssertTrue(shared.changesWhatGuestsSee(from: original))
    }

    /// The live form follows new input except where the user changed a field by hand (§5.2).
    func testLiveFormKeepsHandEdits() {
        let parser = NLParser(now: now)
        let first = EventDraft(parsed: parser.parse("Coffee tomorrow"), account: "me@example.com", calendarId: "primary")
        var form = first
        form.location = "Blue Bottle"   // typed into the form
        let second = EventDraft(parsed: parser.parse("Coffee tomorrow 3pm at Ritual"), account: "me@example.com", calendarId: "primary")
        let next = form.following(second, previousParse: first)
        XCTAssertEqual(next.location, "Blue Bottle")
        XCTAssertFalse(next.allDay)
        XCTAssertEqual(next.start, second.start)
    }
}
