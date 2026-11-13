// Which pending invitations get a "new invitation" notification.
import XCTest
@testable import KalendarCore

final class InvitationNoticesTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-13T15:00:00Z")!
    private let me = "me@example.com", work = "me@work.com"

    private func invite(_ id: String, account: String? = nil, series: String? = nil, startsIn hours: Double = 24) -> EventInstance {
        let start = now.addingTimeInterval(hours * 3600)
        return EventInstance(account: account ?? me, calendarId: "primary", id: id, recurringEventId: series,
                             summary: id, location: nil, notes: nil, start: start, end: start.addingTimeInterval(1800),
                             allDay: false, transparency: nil, colorId: nil, conferenceURL: nil, selfResponse: "needsAction",
                             organizerSelf: false,
                             attendees: [Attendee(email: "boss@example.com", displayName: nil, isSelf: false, organizer: true,
                                                  optional: false, responseStatus: "accepted")],
                             htmlLink: nil, etag: nil, visibility: nil, reminders: Reminders(), timeZone: nil)
    }

    private func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86400) }

    func testFirstSightOfAnAccountRecordsWithoutAnnouncing() {
        let plan = InvitationNotices.plan(pending: [invite("a"), invite("b")], seen: [:], synced: [me], now: now)
        XCTAssertEqual(plan.announce, [])
        XCTAssertEqual(plan.seen, [me: ["\(me)|a": now, "\(me)|b": now]])
    }

    func testANewInvitationIsAnnouncedOnce() {
        let first = InvitationNotices.plan(pending: [invite("a"), invite("b")], seen: [me: ["\(me)|a": days(1)]],
                                           synced: [me], now: now)
        XCTAssertEqual(first.announce.map(\.id), ["b"])
        let second = InvitationNotices.plan(pending: [invite("a"), invite("b")], seen: first.seen, synced: [me], now: now)
        XCTAssertEqual(second.announce, [])
    }

    func testAKeyNoLongerPendingIsKeptUntilRetentionEnds() {
        // a hidden calendar's invitation, shown again within the retention, is not announced again
        let kept = InvitationNotices.plan(pending: [], seen: [me: ["\(me)|a": days(100)]], synced: [me], now: now)
        XCTAssertEqual(kept.seen, [me: ["\(me)|a": days(100)]])
        let back = InvitationNotices.plan(pending: [invite("a")], seen: kept.seen, synced: [me], now: now)
        XCTAssertEqual(back.announce, [])
        let expired = InvitationNotices.plan(pending: [], seen: [me: ["\(me)|a": days(121)]], synced: [me], now: now)
        XCTAssertEqual(expired.seen, [me: [:]])
    }

    func testAPendingKeysTimeIsRefreshedOnlyOnceADay() {
        // an unchanged plan lets the caller skip storing it
        let recent = InvitationNotices.plan(pending: [invite("a")], seen: [me: ["\(me)|a": days(0.5)]], synced: [me], now: now)
        XCTAssertEqual(recent.seen, [me: ["\(me)|a": days(0.5)]])
        let old = InvitationNotices.plan(pending: [invite("a")], seen: [me: ["\(me)|a": days(2)]], synced: [me], now: now)
        XCTAssertEqual(old.seen, [me: ["\(me)|a": now]])
    }

    func testAnAccountNotYetSyncedIsLeftForLater() {
        // the work account signed in but has no synced events: its invitations wait for its first sync
        let pending = [invite("a"), invite("w", account: work)]
        let plan = InvitationNotices.plan(pending: pending, seen: [me: [:]], synced: [me], now: now)
        XCTAssertEqual(plan.announce.map(\.id), ["a"])
        XCTAssertNil(plan.seen[work])
        let synced = InvitationNotices.plan(pending: pending, seen: plan.seen, synced: [me, work], now: now)
        XCTAssertEqual(synced.announce, [], "the work account's first sync records its invitation")
    }

    func testARecurringInvitationIsOneKeyAndEndedOnesAreNotAnnounced() {
        let plan = InvitationNotices.plan(pending: [invite("s_1", series: "s"), invite("old", startsIn: -2)],
                                          seen: [me: [:]], synced: [me], now: now)
        XCTAssertEqual(plan.announce.map(\.id), ["s_1"])
        XCTAssertEqual(plan.seen[me].map { Set($0.keys) }, ["\(me)|s", "\(me)|old"])
    }

    func testASignedOutAccountIsDropped() {
        let plan = InvitationNotices.plan(pending: [], seen: [me: ["\(me)|a": now], work: ["\(work)|w": now]],
                                          synced: [me], now: now)
        XCTAssertEqual(plan.seen, [me: ["\(me)|a": now]])
    }
}
