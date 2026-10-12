// People API parsing and contact suggestions (§5.1, §18.4).
import XCTest
@testable import KalendarCore

final class ContactsTests: XCTestCase {
    func testPeoplePageGivesOneRowPerEmail() throws {
        let json = #"{"connections":[{"names":[{"displayName":"Bob Day"}],"emailAddresses":[{"value":"bob@example.com"},{"value":"bob@gmail.com"}],"photos":[{"url":"https://p/1","default":true},{"url":"https://p/2"}]}],"nextPageToken":"n"}"#
        let page = try JSONDecoder().decode(GooglePeopleAPI.Page.self, from: Data(json.utf8))
        XCTAssertEqual(page.nextPageToken, "n")
        XCTAssertEqual(page.contacts(account: "a").map(\.email), ["bob@example.com", "bob@gmail.com"])
        XCTAssertEqual(page.contacts(account: "a").first?.photoURL, "https://p/2", "a default (generic) photo is skipped")
        let other = try JSONDecoder().decode(GooglePeopleAPI.Page.self, from: Data(#"{"otherContacts":[{"emailAddresses":[{"value":"x@example.com"}]}]}"#.utf8))
        XCTAssertEqual(other.contacts(account: "a").map(\.email), ["x@example.com"])
    }

    func testSuggestionsRankNamePrefixFirstAndIncludeAttendees() throws {
        let cache = try CalendarCache()
        try cache.replaceContacts([
            Contact(account: "a", email: "dana@example.com", name: "Dana Lee", photoURL: nil),
            Contact(account: "a", email: "adam@example.com", name: "Adam Daniels", photoURL: nil),
            Contact(account: "a", email: "sam@dash.com", name: "Sam Ortiz", photoURL: nil),
        ], account: "a")
        try cache.replaceCalendars([CalendarInfo(account: "a", id: "c", summary: "C", backgroundColor: "#000000",
                                                 accessRole: "owner", selected: true, primary: true)], account: "a")
        var e = try XCTUnwrap(JSONDecoder().decode(GoogleCalendarAPI.GoogleEvent.self, from: Data(#"{"id":"e","start":{"date":"2026-10-12"},"end":{"date":"2026-10-13"},"attendees":[{"email":"daria@other.com","displayName":"Daria Quinn"},{"email":"me@a.com","self":true,"displayName":"Dave Me"}]}"#.utf8)).instance(account: "a", calendarId: "c"))
        e.summary = "x"
        try cache.upsert([e])

        let found = try cache.contacts(matching: "da")
        XCTAssertEqual(found.map(\.email), ["adam@example.com", "dana@example.com", "daria@other.com", "sam@dash.com"])
        XCTAssertFalse(found.contains { $0.email == "me@a.com" }, "the user's own attendee entry is not a suggestion")
        XCTAssertEqual(try cache.uniqueContactEmail(named: "dana"), "dana@example.com")
        XCTAssertNil(try cache.uniqueContactEmail(named: "sam lee"))
    }
}
