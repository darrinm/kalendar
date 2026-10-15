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

    /// A directory profile's untyped, non-primary addresses are the domain's aliases (§18.4).
    func testDirectoryAliasesAreMarkedAndNeverSuggested() throws {
        let json = #"""
        {"people":[{"names":[{"displayName":"Mike Harrington"}],"emailAddresses":[
          {"value":"mike@playful.software","metadata":{"primary":true,"source":{"type":"DOMAIN_PROFILE"}}},
          {"value":"mikehar@gmail.com","type":"home","metadata":{"source":{"type":"DOMAIN_PROFILE"}}},
          {"value":"mike@hatch.one","metadata":{"source":{"type":"DOMAIN_PROFILE"}}},
          {"value":"mike@playful.app","metadata":{"source":{"type":"DOMAIN_PROFILE"}}}]}]}
        """#
        let page = try JSONDecoder().decode(GooglePeopleAPI.Page.self, from: Data(json.utf8))
        let directory = page.contacts(account: "work")
        XCTAssertEqual(directory.filter(\.isAlias).map(\.email), ["mike@hatch.one", "mike@playful.app"])

        let cache = try CalendarCache()
        try cache.replaceContacts(directory, account: "work")
        // the same alias saved under the other account, as an "other contact", still isn't suggested
        try cache.replaceContacts([Contact(account: "home", email: "Mike@Hatch.one", name: nil, photoURL: nil),
                                   Contact(account: "home", email: "mike@picnik.com", name: "Mike Harrington", photoURL: nil)],
                                  account: "home")
        XCTAssertEqual(Set(try cache.allContacts().matching("mike").map(\.email)),
                       ["mike@playful.software", "mikehar@gmail.com", "mike@picnik.com"])
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

        let all = try cache.allContacts()
        let found = all.matching("da")
        XCTAssertEqual(found.map(\.email), ["adam@example.com", "dana@example.com", "daria@other.com", "sam@dash.com"])
        XCTAssertFalse(found.contains { $0.email == "me@a.com" }, "the user's own attendee entry is not a suggestion")
        XCTAssertEqual(all.uniqueEmail(named: "dana"), "dana@example.com")
        XCTAssertNil(all.uniqueEmail(named: "sam lee"))
    }
}
