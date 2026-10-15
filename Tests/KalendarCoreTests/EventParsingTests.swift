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

    /// Only an invitation still at needsAction is unanswered; Maybe and the user's own events are not.
    func testUnansweredInvitation() throws {
        func instance(response: String, organizer: String) throws -> EventInstance {
            let e = try event("""
            {"id":"u","summary":"Review","start":{"dateTime":"2026-10-12T09:00:00-07:00"},"end":{"dateTime":"2026-10-12T10:00:00-07:00"},
             "attendees":[{"email":"me@example.com","self":true,"responseStatus":"\(response)"},
                          {"email":"alex@example.com","organizer":true,"responseStatus":"accepted"}],
             "organizer":{"email":"\(organizer)"\(organizer == "me@example.com" ? ",\"self\":true" : "")}}
            """)
            return try XCTUnwrap(e.instance(account: "me@example.com", calendarId: "primary"))
        }
        let pending = try instance(response: "needsAction", organizer: "alex@example.com")
        XCTAssertTrue(pending.isUnanswered)
        XCTAssertTrue(pending.isTentative)
        XCTAssertFalse(try instance(response: "tentative", organizer: "alex@example.com").isUnanswered)
        XCTAssertFalse(try instance(response: "accepted", organizer: "alex@example.com").isUnanswered)
        XCTAssertFalse(try instance(response: "needsAction", organizer: "me@example.com").isUnanswered)
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

    /// The list and alerts show the place, not the video link the 📹 glyph stands for.
    func testLocationShownWithoutVideoLinks() {
        XCTAssertEqual(ConferenceDetector.removingLinks(from: "https://us02web.zoom.us/j/84965702404, Neat Board (20)"),
                       "Neat Board (20)")
        XCTAssertEqual(ConferenceDetector.removingLinks(from: "Room 4, https://zoom.us/j/1234567890?pwd=abc"), "Room 4")
        XCTAssertEqual(ConferenceDetector.removingLinks(from: "https://meet.google.com/abc-defg-hij"), "")
        // no link: the text is left exactly as it is
        XCTAssertEqual(ConferenceDetector.removingLinks(from: "85 Pike St,  Seattle; WA"), "85 Pike St,  Seattle; WA")
        XCTAssertEqual(ConferenceDetector.removingLinks(from: "https://example.com/map, Room 4"),
                       "https://example.com/map, Room 4")
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
        XCTAssertEqual(ConferenceDetector.serviceName(for: "https://notzoom.us/j/1"), "Video")
        XCTAssertEqual(ConferenceDetector.serviceName(for: "https://meet.google.com/a"), "Google Meet")
    }

    func testJoinCandidate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func e(_ id: String, start: TimeInterval, end: TimeInterval, link: String? = "https://zoom.us/j/1",
               allDay: Bool = false, response: String? = nil) -> EventInstance {
            EventInstance(account: "a", calendarId: "c", id: id, recurringEventId: nil, summary: id, location: nil,
                          notes: nil, start: now + start * 60, end: now + end * 60, allDay: allDay, transparency: nil,
                          colorId: nil, conferenceURL: link, selfResponse: response, organizerSelf: true, attendees: [],
                          htmlLink: nil, etag: nil, visibility: nil, timeZone: nil)
        }
        let pick = { (events: [EventInstance]) in ConferenceDetector.joinCandidate(in: events, now: now)?.id }
        XCTAssertEqual(pick([e("now", start: -10, end: 20)]), "now")
        XCTAssertEqual(pick([e("soon", start: 15, end: 45)]), "soon")
        XCTAssertNil(pick([e("later", start: 16, end: 45)]))
        XCTAssertNil(pick([e("over", start: -60, end: 0)]))
        XCTAssertNil(pick([e("nolink", start: 0, end: 30, link: nil)]))
        XCTAssertNil(pick([e("declined", start: 0, end: 30, response: "declined")]))
        XCTAssertNil(pick([e("allday", start: -600, end: 600, allDay: true)]))
        // the one that started or starts last
        XCTAssertEqual(pick([e("running", start: -30, end: 30), e("next", start: 10, end: 40)]), "next")
    }

    func testShortTitleDropsTheUsersName() {
        func short(_ summary: String, selfAttendee: String? = nil) -> String {
            let me = selfAttendee.map { [Attendee(email: "me@x.com", displayName: $0, isSelf: true, organizer: false,
                                                  optional: false, responseStatus: "accepted")] } ?? []
            return EventInstance(account: "a", calendarId: "c", id: "e", recurringEventId: nil, summary: summary,
                                 location: nil, notes: nil, start: Date(), end: Date(), allDay: false, transparency: nil,
                                 colorId: nil, conferenceURL: nil, selfResponse: nil, organizerSelf: false, attendees: me,
                                 htmlLink: nil, etag: nil, visibility: nil, timeZone: nil)
                .shortTitle(selfNames: ["darrin"])
        }
        XCTAssertEqual(short("Darrin/Kate"), "Kate")
        XCTAssertEqual(short("Steve / Darrin"), "Steve")
        XCTAssertEqual(short("Darrin / Jorge 1:1"), "Jorge 1:1")
        XCTAssertEqual(short("Anthony <> Darrin"), "Anthony")
        XCTAssertEqual(short("Darrin x Kate"), "Kate")
        XCTAssertEqual(short("Kate & Sam / Darrin"), "Kate / Sam")
        XCTAssertEqual(short("Pat / Kim", selfAttendee: "Pat Lee"), "Kim")
        XCTAssertEqual(short("UXR readout"), "UXR readout")
        XCTAssertEqual(short("Darrin"), "Darrin")
        XCTAssertEqual(short("Engineering Standup and Planning"), "Engineering Standup…")
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
