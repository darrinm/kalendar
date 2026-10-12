// Which alerts Kalendar schedules (§19).
import XCTest
@testable import KalendarCore

final class AlertPlannerTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-12T17:00:00Z")!

    private func event(_ id: String, startsIn minutes: Double, reminders: Reminders = Reminders(useDefault: false, minutes: [10]),
                       allDay: Bool = false, response: String? = nil, calendar: String = "primary",
                       summary: String? = nil) -> EventInstance {
        let start = now.addingTimeInterval(minutes * 60)
        return EventInstance(account: "me@example.com", calendarId: calendar, id: id, recurringEventId: nil,
                             summary: summary ?? id, location: nil, notes: nil, start: start, end: start.addingTimeInterval(1800),
                             allDay: allDay, transparency: nil, colorId: nil, conferenceURL: nil, selfResponse: response,
                             organizerSelf: true, attendees: [], htmlLink: nil, etag: nil, visibility: nil,
                             reminders: reminders, timeZone: nil)
    }

    private let calendars = ["me@example.com|primary": CalendarInfo(
        account: "me@example.com", id: "primary", summary: "Me", backgroundColor: "#000000", accessRole: "owner",
        selected: true, primary: true, defaultReminders: [30])]

    func testOwnRemindersAndCalendarDefaults() {
        let plan = AlertPlanner.plan(events: [
            event("own", startsIn: 60, reminders: Reminders(useDefault: false, minutes: [10, 15])),
            event("defaults", startsIn: 120, reminders: Reminders(useDefault: true, minutes: [])),
        ], calendars: calendars, now: now)
        XCTAssertEqual(plan.map(\.identifier), ["primary|own|15", "primary|own|10", "primary|defaults|30"])
        XCTAssertEqual(plan[0].fireDate, now.addingTimeInterval(45 * 60))
    }

    func testOnlyTheNext24HoursAndNotPastOrDeclined() {
        let plan = AlertPlanner.plan(events: [
            event("past", startsIn: 5),                      // fired 5 minutes ago
            event("tomorrowLate", startsIn: 25 * 60),        // fires after the horizon
            event("declined", startsIn: 60, response: "declined"),
            event("soon", startsIn: 30),
        ], calendars: calendars, now: now)
        XCTAssertEqual(plan.map(\.identifier), ["primary|soon|10"])
    }

    func testAllDayCountsBackFromMidnight() {
        // all-day events start at local midnight in the cache
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86400))
        var e = event("holiday", startsIn: midnight.timeIntervalSince(now) / 60,
                      reminders: Reminders(useDefault: false, minutes: [9 * 60]), allDay: true)
        e.end = midnight.addingTimeInterval(86400)
        let plan = AlertPlanner.plan(events: [e], calendars: calendars, now: now)
        XCTAssertEqual(plan.first?.fireDate, midnight.addingTimeInterval(-9 * 3600))
    }

    func testAtMost64AndDuplicatesOnce() {
        let many = (0..<100).map { event("e\($0)", startsIn: Double(20 + $0)) }
        XCTAssertEqual(AlertPlanner.plan(events: many, calendars: calendars, now: now).count, AlertPlanner.limit)
        let twice = [event("a", startsIn: 60, summary: "Sync"), event("b", startsIn: 60, calendar: "other", summary: "Sync")]
        XCTAssertEqual(AlertPlanner.plan(events: twice, calendars: calendars, now: now).count, 1)
    }
}
