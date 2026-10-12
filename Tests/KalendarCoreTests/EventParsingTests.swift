// Google event JSON → EventInstance, and conference-link detection.
import XCTest
@testable import KalendarCore

final class EventParsingTests: XCTestCase {
    private func event(_ json: String) throws -> GoogleCalendarAPI.GoogleEvent {
        try JSONDecoder().decode(GoogleCalendarAPI.GoogleEvent.self, from: Data(json.utf8))
    }

    func testTimedEventWithAttendeesAndMeet() throws {
        let e = try event("""
        {"id":"e1","status":"confirmed","summary":"Team sync","location":"Room 4",
         "start":{"dateTime":"2026-10-12T09:00:00-07:00"},"end":{"dateTime":"2026-10-12T10:00:00-07:00"},
         "hangoutLink":"https://meet.google.com/abc-defg-hij",
         "conferenceData":{"entryPoints":[{"entryPointType":"phone","uri":"tel:+1"},
                                          {"entryPointType":"video","uri":"https://meet.google.com/abc-defg-hij"}]},
         "attendees":[{"email":"me@example.com","self":true,"responseStatus":"tentative"},
                      {"email":"alex@example.com","displayName":"Alex","organizer":true,"responseStatus":"accepted"}],
         "organizer":{"email":"alex@example.com"}}
        """)
        let i = try XCTUnwrap(e.instance(account: "me@example.com", calendarId: "primary"))
        XCTAssertEqual(i.summary, "Team sync")
        XCTAssertFalse(i.allDay)
        XCTAssertEqual(i.start, ISO8601DateFormatter().date(from: "2026-10-12T16:00:00Z"))
        XCTAssertEqual(i.end.timeIntervalSince(i.start), 3600)
        XCTAssertEqual(i.conferenceURL, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(i.selfResponse, "tentative")
        XCTAssertTrue(i.isTentative)
        XCTAssertFalse(i.organizerSelf)
        XCTAssertEqual(i.attendees.map(\.email), ["me@example.com", "alex@example.com"])
        XCTAssertTrue(i.attendees[0].isSelf)
        XCTAssertTrue(i.attendees[1].organizer)
    }

    /// All-day dates are calendar days: midnight local time, end exclusive.
    func testAllDayEventUsesLocalMidnight() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let e = try event(#"{"id":"h","summary":"Columbus Day","start":{"date":"2026-10-12"},"end":{"date":"2026-10-13"}}"#)
        let i = try XCTUnwrap(e.instance(account: "a", calendarId: "c", calendar: cal))
        XCTAssertTrue(i.allDay)
        XCTAssertEqual(i.start, cal.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        XCTAssertEqual(i.end, cal.date(from: DateComponents(year: 2026, month: 10, day: 13)))
    }

    func testCancelledEventHasNoInstance() throws {
        let e = try event(#"{"id":"x","status":"cancelled"}"#)
        XCTAssertTrue(e.isCancelled)
        XCTAssertNil(e.instance(account: "a", calendarId: "c"))
    }

    func testMissingTitleAndRecurrenceFields() throws {
        let master = try event(#"{"id":"m","recurrence":["RRULE:FREQ=WEEKLY"],"start":{"date":"2026-10-12"},"end":{"date":"2026-10-13"}}"#)
        XCTAssertTrue(master.isRecurringMaster)
        XCTAssertEqual(master.instance(account: "a", calendarId: "c")?.summary, "(No title)")
        let exception = try event(#"{"id":"m_20261019","recurringEventId":"m","start":{"date":"2026-10-19"},"end":{"date":"2026-10-20"}}"#)
        XCTAssertEqual(exception.recurringEventId, "m")
        XCTAssertFalse(exception.isRecurringMaster)
    }

    func testConferenceLinksFoundInLocationAndNotes() {
        XCTAssertEqual(ConferenceDetector.url(in: ["https://us02web.zoom.us/j/84965702404, Board room"]),
                       "https://us02web.zoom.us/j/84965702404")
        XCTAssertEqual(ConferenceDetector.url(in: [nil, "Join: https://meet.google.com/abc-defg-hij."]),
                       "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(ConferenceDetector.url(in: ["<a href=\"https://teams.microsoft.com/l/meetup-join/19%3a\">x</a>"]),
                       "https://teams.microsoft.com/l/meetup-join/19%3a")
        XCTAssertNil(ConferenceDetector.url(in: ["https://example.com/meeting", "Room 4"]))
        XCTAssertEqual(ConferenceDetector.serviceName(for: "https://us02web.zoom.us/j/1"), "Zoom")
        XCTAssertEqual(ConferenceDetector.serviceName(for: "https://meet.google.com/a"), "Google Meet")
    }

    /// Location is checked before notes, so a Zoom room in the location wins over a Meet link in notes.
    func testLocationBeatsNotes() throws {
        let e = try event("""
        {"id":"e","start":{"dateTime":"2026-10-12T09:00:00Z"},"end":{"dateTime":"2026-10-12T10:00:00Z"},
         "location":"https://zoom.us/j/1","description":"or https://meet.google.com/x-y-z"}
        """)
        XCTAssertEqual(e.instance(account: "a", calendarId: "c")?.conferenceURL, "https://zoom.us/j/1")
    }

    func testCalendarIdIsEscapedInPaths() {
        let r = GoogleCalendarAPI.windowRequest(calendarId: "en.usa#holiday@group.v.calendar.google.com",
                                                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 86400),
                                                pageToken: nil)("tok")
        XCTAssertTrue(r.url!.absoluteString.contains("/calendars/en.usa%23holiday@group.v.calendar.google.com/events"))
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "singleEvents" }?.value, "true")
        XCTAssertEqual(q.first { $0.name == "timeMin" }?.value, "1970-01-01T00:00:00Z")
    }
}
