// The natural-language parser (§5.2, §5.3) against Fixtures/nl-corpus.json, plus the parts the
// corpus can't express: suggestion triggers, contacts, calendars, task prefix.
import XCTest
@testable import KalendarCore

final class NLParserTests: XCTestCase {
    private struct Corpus: Decodable {
        struct Case: Decodable {
            var input: String
            var title: String
            var location: String?
            var start: String
            var end: String
            var allDay: Bool
            var alerts: [Int]?
            var rrule: String?
        }
        var now: String
        var timeZone: String
        var cases: [Case]
    }

    private var calendar: Calendar!
    private var formatter: DateFormatter!

    override func setUp() {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US")
        formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
    }

    private func parser(matcher: @escaping (String) -> String? = { _ in nil }) -> NLParser {
        NLParser(now: formatter.date(from: "2026-09-21 10:00")!, calendar: calendar, contactMatcher: matcher)
    }

    func testCorpus() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "nl-corpus", withExtension: "json", subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.now, "2026-09-21 10:00")
        XCTAssertEqual(corpus.cases.count, 28, "every case in the corpus runs")
        let p = parser()
        var checked = 0
        defer { XCTAssertEqual(checked, corpus.cases.count) }
        for c in corpus.cases {
            let item = p.parse(c.input)
            let label = "“\(c.input)”"
            XCTAssertEqual(item.title, c.title, label)
            checked += 1
            XCTAssertEqual(item.location, c.location, label)
            XCTAssertEqual(formatter.string(from: item.start), c.start, label)
            XCTAssertEqual(formatter.string(from: item.end), c.end, label)
            XCTAssertEqual(item.allDay, c.allDay, label)
            XCTAssertEqual(item.alerts, c.alerts ?? [], label)
            XCTAssertEqual(item.recurrence?.rrule(calendar: calendar, allDay: item.allDay), c.rrule, label)
        }
    }

    /// The title updates live as tokens are recognized (§5.2): "Coffee" while the rest is typed.
    func testTitleWhileTyping() {
        let p = parser()
        XCTAssertEqual(p.parse("Coffee tom").title, "Coffee tom")
        XCTAssertEqual(p.parse("Coffee tomorrow").title, "Coffee")
        XCTAssertEqual(p.parse("Coffee tomorrow 3").title, "Coffee 3")
        XCTAssertEqual(p.parse("Coffee tomorrow 3pm at T").title, "Coffee")
    }

    func testSuggestionTriggers() throws {
        let p = parser()
        let calendar = try XCTUnwrap(p.parse("/m").trigger)
        XCTAssertEqual(calendar.kind, .calendar)
        XCTAssertEqual(calendar.query, "m")

        let text = "Sync with Da"
        let contact = try XCTUnwrap(p.parse(text).trigger)
        XCTAssertEqual(contact.kind, .contact)
        XCTAssertEqual(contact.query, "Da")
        XCTAssertEqual(String(text[contact.range]), "with Da")
        XCTAssertEqual(p.parse(text).title, "Sync with Da", "an unmatched name stays in the title")

        let place = try XCTUnwrap(p.parse("Coffee at Blue Bot").trigger)
        XCTAssertEqual(place.kind, .location)
        XCTAssertEqual(place.query, "Blue Bot")

        XCTAssertNil(p.parse("Coffee at Blue Bottle ").trigger, "a trailing space ends the suggestion")
        XCTAssertNil(p.parse("Coffee at 3pm").trigger, "a time after at is not a place")
    }

    func testMatchedContactBecomesAnInvitee() {
        let item = parser { $0 == "Dana" ? "dana@example.com" : nil }.parse("Standup at 9:30 with Dana")
        XCTAssertEqual(item.title, "Standup")
        XCTAssertEqual(item.invitees, ["dana@example.com"])
    }

    func testCalendarAndTaskPrefixes() {
        let p = parser()
        let gym = p.parse("/test Gym 6pm")
        XCTAssertEqual(gym.calendarQuery, "test")
        XCTAssertEqual(gym.title, "Gym")

        let task = p.parse("todo buy milk tomorrow")
        XCTAssertTrue(task.isTask)
        XCTAssertTrue(task.hasDate)
        XCTAssertEqual(task.title, "buy milk")
        XCTAssertFalse(p.parse("ddd").hasDate)
    }

    /// Double-clicking a day pre-dates an entry that names no date (§4.2).
    func testDefaultDay() {
        var p = parser()
        p.defaultDay = formatter.date(from: "2026-10-05 00:00")
        XCTAssertEqual(formatter.string(from: p.parse("Lunch noon").start), "2026-10-05 12:00")
        XCTAssertEqual(formatter.string(from: p.parse("Lunch tomorrow noon").start), "2026-09-22 12:00")
    }

    func testClockReadings() {
        XCTAssertEqual(NLParser.clock("3pm", bareNumbers: false).map { [$0.h, $0.m] }, [15, 0])
        XCTAssertEqual(NLParser.clock("12am", bareNumbers: false).map { [$0.h, $0.m] }, [0, 0])
        XCTAssertEqual(NLParser.clock("12:30pm", bareNumbers: false).map { [$0.h, $0.m] }, [12, 30])
        XCTAssertEqual(NLParser.clock("15:00", bareNumbers: false).map { [$0.h, $0.m] }, [15, 0])
        XCTAssertNil(NLParser.clock("3", bareNumbers: false), "a bare number is not a time on its own")
        XCTAssertEqual(NLParser.clock("9", bareNumbers: true).map { [$0.h, $0.m] }, [9, 0])
        XCTAssertNil(NLParser.clock("13pm", bareNumbers: false))
    }
}
