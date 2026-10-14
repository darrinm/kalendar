// Meet With (§21): other people's time over the user's own, so the user can find a slot open to
// everyone. Each person's events come from their calendar when it is shared with one of the
// user's accounts (titles), else from the free/busy query (busy blocks only).
import Foundation

public enum Availability {
    /// One busy stretch in someone's day. `title` is nil when only free/busy is visible.
    public struct Block: Equatable, Hashable, Sendable {
        public var start: Date
        public var end: Date
        public var title: String?

        public init(start: Date, end: Date, title: String?) {
            self.start = start
            self.end = end
            self.title = title
        }
    }

    /// What Kalendar could see of one person's calendar.
    public enum Schedule: Equatable, Sendable {
        /// Their calendar is shared with one of the user's accounts: events with titles.
        case events([Block])
        /// Only free/busy is visible.
        case busy([Block])
        /// Google returned neither, for example someone outside the user's organization.
        case unavailable

        public var blocks: [Block] {
            switch self {
            case .events(let b), .busy(let b): b
            case .unavailable: []
            }
        }
    }

    /// Loads `email`'s timed events in [from, to). Accounts in the person's email domain are tried
    /// first, since a Workspace shares calendars and free/busy within the organization.
    @MainActor
    public static func load(_ email: String, from: Date, to: Date, accounts: AccountStore) async -> Schedule {
        let domain = "@" + (email.split(separator: "@").last?.lowercased() ?? "")
        let all = accounts.accounts.map(\.email)
        let ordered = all.filter { $0.lowercased().hasSuffix(domain) } + all.filter { !$0.lowercased().hasSuffix(domain) }
        for account in ordered {
            if let blocks = try? await events(of: email, from: from, to: to, account: account, accounts: accounts) {
                return .events(blocks)
            }
        }
        for account in ordered {
            if let blocks = try? await busy(of: email, from: from, to: to, account: account, accounts: accounts) {
                return .busy(blocks)
            }
        }
        return .unavailable
    }

    /// Their calendar's events, read as `account`. Throws when it isn't shared with that account.
    @MainActor
    static func events(of email: String, from: Date, to: Date, account: String,
                       accounts: AccountStore) async throws -> [Block] {
        var blocks: [Block] = []
        var token: String?
        repeat {
            let page = try await accounts.calendarAPI(GoogleCalendarAPI.EventsPage.self, for: account,
                GoogleCalendarAPI.windowRequest(calendarId: email, from: from, to: to, pageToken: token))
            blocks += (page.items ?? []).compactMap { g in
                guard let e = g.instance(account: account, calendarId: email), !e.allDay,
                      e.transparency != "transparent",
                      // events they declined don't hold their time
                      e.attendees.first(where: { $0.email.lowercased() == email.lowercased() })?.responseStatus != "declined"
                else { return nil }
                return Block(start: e.start, end: e.end, title: g.summary)
            }
            token = page.nextPageToken
        } while token != nil
        return blocks.sorted { $0.start < $1.start }
    }

    /// Their busy times from the free/busy query, asked as `account`. Throws when Google reports an
    /// error for that calendar (not found, or no access).
    @MainActor
    static func busy(of email: String, from: Date, to: Date, account: String,
                     accounts: AccountStore) async throws -> [Block] {
        let response = try await accounts.calendarAPI(GoogleCalendarAPI.FreeBusyResponse.self, for: account,
            GoogleCalendarAPI.freeBusyRequest(emails: [email], from: from, to: to))
        guard let calendar = response.calendars?[email] ?? response.calendars?[email.lowercased()],
              calendar.errors?.isEmpty ?? true else { throw GoogleCalendarAPI.APIError.notFound }
        return (calendar.busy ?? []).compactMap { b in
            guard let s = GoogleCalendarAPI.parseInstant(b.start), let e = GoogleCalendarAPI.parseInstant(b.end) else { return nil }
            return Block(start: s, end: e, title: nil)
        }
    }

    /// Side-by-side columns for overlapping blocks in one person's column: each block's column and
    /// the number of columns in its overlapping group. Blocks that touch end to start don't overlap.
    public static func lanes(_ blocks: [Block]) -> [(block: Block, lane: Int, lanes: Int)] {
        let sorted = blocks.sorted { ($0.start, $1.end) < ($1.start, $0.end) }
        var result: [(block: Block, lane: Int, lanes: Int)] = []
        var group: [(block: Block, lane: Int)] = []
        var groupEnd = Date.distantPast
        func close() {
            let count = (group.map(\.lane).max() ?? -1) + 1
            result += group.map { ($0.block, $0.lane, count) }
            group = []
        }
        for b in sorted {
            if b.start >= groupEnd { close() }
            // the first column whose last block has ended
            var lane = 0
            while group.contains(where: { $0.lane == lane && $0.block.end > b.start }) { lane += 1 }
            group.append((b, lane))
            groupEnd = max(groupEnd, b.end)
        }
        close()
        return result
    }
}
