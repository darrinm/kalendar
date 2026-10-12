// RecurrenceRule (repeat / repeat end, §6.1) and EventDraft's patch bodies.
import XCTest
@testable import KalendarCore

final class RecurrenceAndDraftTests: XCTestCase {
    private var la: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    func testParsesAndWritesBack() throws {
        let r = try XCTUnwrap(RecurrenceRule(rrule: "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"))
        XCTAssertEqual(r.frequency, .weekly)
        XCTAssertEqual(r.interval, 2)
        XCTAssertEqual(r.weekdays, [2, 4])
        XCTAssertEqual(r.end, .never)
        XCTAssertEqual(r.rrule(), "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE")
    }

    /// Parts Kalendar doesn't edit survive a round trip.
    func testKeepsPartsItDoesNotEdit() throws {
        let r = try XCTUnwrap(RecurrenceRule(rrule: "RRULE:FREQ=MONTHLY;BYDAY=1MO;WKST=SU"))
        XCTAssertTrue(r.weekdays.isEmpty)
        XCTAssertNil(r.preset)
        XCTAssertEqual(r.rrule(), "RRULE:FREQ=MONTHLY;BYDAY=1MO;WKST=SU")
    }

    func testEnds() throws {
        let count = try XCTUnwrap(RecurrenceRule(rrule: "RRULE:FREQ=DAILY;COUNT=5"))
        XCTAssertEqual(count.end, .count(5))
        XCTAssertEqual(count.endSummary, "After 5 times")

        // UNTIL is the end of that local day, in UTC
        var until = RecurrenceRule(frequency: .weekly)
        until.end = .until(la.date(from: DateComponents(year: 2026, month: 12, day: 31))!)
        XCTAssertEqual(until.rrule(calendar: la), "RRULE:FREQ=WEEKLY;UNTIL=20270101T075959Z")
        let parsed = try XCTUnwrap(RecurrenceRule(rrule: until.rrule(calendar: la)))
        guard case .until(let day) = parsed.end else { return XCTFail("expected until") }
        XCTAssertEqual(la.component(.day, from: day), 31)
    }

    func testPresetsAndSummaries() throws {
        XCTAssertEqual(RecurrenceRule(frequency: .weekly).preset, .weekly)
        XCTAssertEqual(RecurrenceRule(frequency: .weekly).summary(), "Every Week")
        let weekdays = RecurrenceRule(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])
        XCTAssertNil(weekdays.preset)
        XCTAssertEqual(weekdays.summary(calendar: la), "Every week on Monday, Tuesday, Wednesday, Thursday and Friday")
        XCTAssertEqual(RecurrenceRule(frequency: .monthly, interval: 3).summary(), "Every 3 months")
    }

    func testReplacingKeepsExceptions() {
        let rec = ["RRULE:FREQ=WEEKLY", "EXDATE;TZID=America/Los_Angeles:20261019T090000"]
        XCTAssertEqual(RecurrenceRule.replacing(RecurrenceRule(frequency: .daily), in: rec),
                       ["RRULE:FREQ=DAILY", "EXDATE;TZID=America/Los_Angeles:20261019T090000"])
        XCTAssertEqual(RecurrenceRule.replacing(nil, in: rec), ["EXDATE;TZID=America/Los_Angeles:20261019T090000"])
    }

    // MARK: Drafts

    private func event(allDay: Bool = false) -> EventInstance {
        let start = ISO8601DateFormatter().date(from: "2026-10-12T16:00:00Z")!
        return EventInstance(account: "me@example.com", calendarId: "primary", id: "e1", recurringEventId: nil,
                             summary: "Standup", location: nil, notes: nil, start: start,
                             end: start.addingTimeInterval(1800), allDay: allDay, transparency: nil, colorId: nil,
                             conferenceURL: nil, selfResponse: nil, organizerSelf: true, attendees: [], htmlLink: nil,
                             etag: "\"1\"", visibility: nil, reminders: Reminders(), timeZone: "America/Los_Angeles")
    }

    func testNoChangesNoBody() {
        let d = EventDraft(event(), recurrence: nil)
        XCTAssertNil(d.patchBody(from: d))
    }

    func testOnlyChangedFieldsArePatched() throws {
        let original = EventDraft(event(), recurrence: nil)
        var d = original
        d.summary = "Standup (moved)"
        d.busy = false
        d.reminders = Reminders(useDefault: false, minutes: [10, 0])
        let body = try XCTUnwrap(d.patchBody(from: original))
        XCTAssertEqual(Set(body.keys), ["summary", "transparency", "reminders"])
        XCTAssertEqual(body["transparency"] as? String, "transparent")
        let reminders = try XCTUnwrap(body["reminders"] as? [String: Any])
        XCTAssertEqual(reminders["useDefault"] as? Bool, false)
        XCTAssertEqual((reminders["overrides"] as? [[String: Any]])?.compactMap { $0["minutes"] as? Int }, [10, 0])
    }

    func testSwitchingToAllDayClearsDateTime() throws {
        let original = EventDraft(event(), recurrence: nil)
        var d = original
        d.allDay = true
        d.start = la.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        d.end = la.date(from: DateComponents(year: 2026, month: 10, day: 13))!
        let body = try XCTUnwrap(d.patchBody(from: original, calendar: la))
        let start = try XCTUnwrap(body["start"] as? [String: Any])
        XCTAssertEqual(start["date"] as? String, "2026-10-12")
        XCTAssertTrue(start["dateTime"] is NSNull)
        XCTAssertEqual((body["end"] as? [String: Any])?["date"] as? String, "2026-10-13")
    }

    /// "All" on a recurring event moves the series by the same offset as this occurrence (§8.1).
    func testSeriesEditShiftsMasterTimes() throws {
        let original = EventDraft(event(), recurrence: RecurrenceRule(frequency: .weekly))
        var d = original
        d.start = original.start.addingTimeInterval(3600)
        d.end = original.end.addingTimeInterval(3600)
        let masterStart = ISO8601DateFormatter().date(from: "2026-01-05T17:00:00Z")!
        let body = try XCTUnwrap(d.patchBody(from: original, seriesTimes: (masterStart, masterStart.addingTimeInterval(1800))))
        XCTAssertEqual((body["start"] as? [String: Any])?["dateTime"] as? String, "2026-01-05T18:00:00Z")
        XCTAssertEqual((body["end"] as? [String: Any])?["dateTime"] as? String, "2026-01-05T18:30:00Z")
    }

    func testRSVPChangesOnlyTheUsersEntry() throws {
        let attendees = [Attendee(email: "me@example.com", displayName: nil, isSelf: true, organizer: false, optional: true, responseStatus: "needsAction"),
                         Attendee(email: "alex@example.com", displayName: "Alex", isSelf: false, organizer: true, optional: false, responseStatus: "accepted")]
        let body = EventDraft.rsvpBody(attendees: attendees, response: "declined")
        let list = try XCTUnwrap(body["attendees"] as? [[String: Any]])
        XCTAssertEqual(list.map { $0["responseStatus"] as? String }, ["declined", "accepted"])
        XCTAssertEqual(list[0]["optional"] as? Bool, true)
        XCTAssertEqual(list[1]["displayName"] as? String, "Alex")
    }
}
