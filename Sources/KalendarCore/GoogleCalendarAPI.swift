// Calendar API v3 calls. Milestone 1 needs only the calendar list, which Settings › Accounts uses
// to show each account's calendar count and so prove the token works. Sync arrives in milestone 2.
import Foundation

public enum GoogleCalendarAPI {
    public struct CalendarSummary: Decodable, Equatable {
        public var id: String
        public var summary: String
        public var accessRole: String
    }

    private struct ListJSON: Decodable { var items: [CalendarSummary]? }

    public static func calendarListRequest(accessToken: String) -> URLRequest {
        var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        c.queryItems = [.init(name: "maxResults", value: "250"),
                        .init(name: "fields", value: "items(id,summary,accessRole)")]
        var request = URLRequest(url: c.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func parseCalendarList(data: Data, status: Int) throws -> [CalendarSummary] {
        guard (200..<300).contains(status) else { throw GoogleOAuth.Error.server("HTTP \(status)") }
        guard let json = try? JSONDecoder().decode(ListJSON.self, from: data) else {
            throw GoogleOAuth.Error.malformedResponse
        }
        return json.items ?? []
    }
}

extension AccountStore {
    public func calendars(for email: String) async throws -> [GoogleCalendarAPI.CalendarSummary] {
        let (data, status) = try await sendAuthorized(for: email, GoogleCalendarAPI.calendarListRequest)
        return try GoogleCalendarAPI.parseCalendarList(data: data, status: status)
    }

    /// "3 calendars", or why the list couldn't be loaded. Settings › Accounts and the account detail
    /// popover show this until milestone 2 replaces it with synced data.
    public func calendarCountText(for email: String) async -> String {
        do {
            let n = try await calendars(for: email).count
            return n == 1 ? "1 calendar" : "\(n) calendars"
        } catch {
            return "Couldn't load calendars: \(error.localizedDescription)"
        }
    }
}
