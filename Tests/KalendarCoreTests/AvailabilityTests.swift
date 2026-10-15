// Meet With (§21): loading other people's time, and laying out overlapping blocks.
import XCTest
@testable import KalendarCore

@MainActor
final class AvailabilityTests: XCTestCase {
    private let google = FakeGoogle()
    private var accounts: AccountStore!
    private let from = ISO8601DateFormatter().date(from: "2026-10-12T07:00:00Z")!
    private var to: Date { from.addingTimeInterval(7 * 86400) }
    private let kate = "kate@work.example.com"

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "AvailabilityTests")!
        defaults.removePersistentDomain(forName: "AvailabilityTests")
        defaults.set(["me@example.com", "darrin@work.example.com"], forKey: "accounts")
        let google = self.google
        accounts = AccountStore(defaults: defaults, vault: StubVault(), transport: { try await google($0) })
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        from.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    func testSharedCalendarGivesTitlesWithoutFreeDeclinedOrAllDayEvents() async {
        google.handler = { request, _ in
            guard request.url!.path == "/calendar/v3/calendars/\(self.kate)/events" else { return (404, "{}") }
            return (200, """
            {"items":[
             {"id":"a","summary":"Planning","start":{"dateTime":"2026-10-12T16:00:00Z"},"end":{"dateTime":"2026-10-12T17:00:00Z"}},
             {"id":"b","summary":"Focus","transparency":"transparent",
              "start":{"dateTime":"2026-10-12T18:00:00Z"},"end":{"dateTime":"2026-10-12T19:00:00Z"}},
             {"id":"c","summary":"Skipped","attendees":[{"email":"kate@work.example.com","responseStatus":"declined"}],
              "start":{"dateTime":"2026-10-12T20:00:00Z"},"end":{"dateTime":"2026-10-12T21:00:00Z"}},
             {"id":"d","summary":"Holiday","start":{"date":"2026-10-13"},"end":{"date":"2026-10-14"}}
            ]}
            """)
        }
        let schedule = await Availability.load(kate, from: from, to: to, accounts: accounts)
        XCTAssertEqual(schedule, .events([Availability.Block(start: at(9), end: at(10), title: "Planning")]))
        XCTAssertEqual(google.log.count, 1, "the first account read it, so no free/busy query")
    }

    func testFallsBackToFreeBusy() async throws {
        google.handler = { request, _ in
            guard request.url!.path == "/calendar/v3/freeBusy" else { return (404, "{}") }
            return (200, """
            {"calendars":{"kate@work.example.com":{"busy":[{"start":"2026-10-12T16:00:00Z","end":"2026-10-12T16:30:00Z"}]}}}
            """)
        }
        let schedule = await Availability.load(kate, from: from, to: to, accounts: accounts)
        XCTAssertEqual(schedule, .busy([Availability.Block(start: at(9), end: at(9, 30), title: nil)]))
        let query = try XCTUnwrap(google.requests.first { $0.httpMethod == "POST" }?.json)
        XCTAssertEqual((query["items"] as? [[String: String]])?.first?["id"], kate)
        XCTAssertEqual(query["timeMin"] as? String, "2026-10-12T07:00:00Z")
    }

    func testUnavailableWhenGoogleReportsAnError() async {
        google.handler = { request, _ in
            guard request.url!.path == "/calendar/v3/freeBusy" else { return (404, "{}") }
            return (200, #"{"calendars":{"kate@work.example.com":{"errors":[{"reason":"notFound"}],"busy":[]}}}"#)
        }
        let schedule = await Availability.load(kate, from: from, to: to, accounts: accounts)
        XCTAssertEqual(schedule, .unavailable)
        // events then free/busy, through each of the two accounts
        XCTAssertEqual(google.log.count, 4)
    }

    func testLanesPutOverlapsSideBySide() {
        let a = Availability.Block(start: at(9), end: at(10), title: "a")
        let b = Availability.Block(start: at(9, 30), end: at(11), title: "b")
        let c = Availability.Block(start: at(10), end: at(10, 30), title: "c")
        let d = Availability.Block(start: at(11), end: at(12), title: "d")
        let laid = Availability.lanes([d, c, b, a], start: \.start, end: \.end).map { "\($0.item.title!)\($0.lane)/\($0.lanes)" }
        // c reuses a's column once a ends; d starts after the group, alone
        XCTAssertEqual(laid, ["a0/2", "b1/2", "c0/2", "d0/1"])
    }
}
