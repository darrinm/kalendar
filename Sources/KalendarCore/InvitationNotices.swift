// Which pending invitations get a "new invitation" notification. Kalendar remembers each invitation
// it has seen, by account, with the last time it was pending. An invitation not remembered is new.
// An account seen for the first time is recorded without notifications, so a first launch or a new
// sign-in does not post one notification per invitation already waiting. A key is kept for
// `retention` after it stops being pending, so a calendar hidden and shown again does not announce
// its invitations a second time.
import Foundation

public enum InvitationNotices {
    /// Longer than `CalendarCache.pendingInvitations`' 90-day window.
    public static let retention: TimeInterval = 120 * 86400

    /// How stale a pending key's time may get before it is refreshed. Refreshing it on every call
    /// would change `seen` on every call, and the caller would store it each time.
    static let refresh: TimeInterval = 86400

    public struct Plan: Equatable {
        /// Invitations to notify about, in the order given.
        public var announce: [EventInstance]
        /// The keys (`EventInstance.seriesKey`) to remember, by account, each with the last time it
        /// was pending, to within `refresh`.
        public var seen: [String: [String: Date]]
    }

    /// - Parameters:
    ///   - pending: `CalendarCache.pendingInvitations`.
    ///   - seen: the keys remembered so far, by account. nil for an account means it was never seen.
    ///   - synced: the accounts whose invitation calendars have all synced. An account not in it is
    ///     dropped, so the sync that completes it records its invitations instead of announcing them.
    ///     That covers a new sign-in, a newly shown calendar, and a signed-out account.
    public static func plan(pending: [EventInstance], seen: [String: [String: Date]], synced: Set<String>, now: Date) -> Plan {
        let announce = pending.filter { event in
            guard synced.contains(event.account), let known = seen[event.account] else { return false }
            return known[event.seriesKey] == nil && event.end > now
        }
        var next: [String: [String: Date]] = [:]
        for account in synced {
            next[account] = (seen[account] ?? [:]).filter { now.timeIntervalSince($0.value) < retention }
        }
        for event in pending where synced.contains(event.account) {
            if let last = next[event.account]![event.seriesKey], now.timeIntervalSince(last) < refresh { continue }
            next[event.account]![event.seriesKey] = now
        }
        return Plan(announce: announce, seen: next)
    }
}
