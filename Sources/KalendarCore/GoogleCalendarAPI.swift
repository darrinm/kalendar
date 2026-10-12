// Calendar API v3: request builders and response parsing. AccountStore sends the requests.
import Foundation

public enum GoogleCalendarAPI {
    static let base = "https://www.googleapis.com/calendar/v3"

    /// The fields Kalendar reads from an event. Asking for only these keeps pages small.
    static let eventFields = "id,status,summary,location,description,start,end,recurringEventId,recurrence,"
        + "transparency,colorId,hangoutLink,conferenceData(entryPoints(entryPointType,uri)),"
        + "attendees(email,displayName,self,organizer,optional,responseStatus),organizer(email,self),htmlLink"

    public enum APIError: Error, Equatable, LocalizedError {
        /// 410: the sync token expired; the calendar needs a full sync.
        case syncTokenExpired
        /// 404: the calendar or event no longer exists.
        case notFound
        case http(Int)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .syncTokenExpired: "Google asked for a full resync."
            case .notFound: "Google no longer has this calendar or event."
            case .http(let status): "Google returned an error (HTTP \(status))."
            case .malformedResponse: "Google returned a response Kalendar couldn't read."
            }
        }
    }

    // MARK: Requests

    /// A request builder: AccountStore calls it with the account's current access token.
    public typealias Builder = (String) -> URLRequest

    static func request(_ path: String, _ query: [String: String?], method: String = "GET",
                        body: Data? = nil, accessToken: String) -> URLRequest {
        var c = URLComponents(string: base + path)!
        c.queryItems = query.sorted { $0.key < $1.key }.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.httpBody = body
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Calendar and event ids contain characters like `#` and `@` that must be escaped in a path.
    static func pathSegment(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/#?")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    public static func calendarListRequest(pageToken: String? = nil) -> Builder {
        { request("/users/me/calendarList", [
            "maxResults": "250", "pageToken": pageToken,
            "fields": "nextPageToken,items(id,summary,summaryOverride,backgroundColor,accessRole,selected,primary)",
        ], accessToken: $0) }
    }

    public static func colorsRequest() -> Builder {
        { request("/colors", ["fields": "event"], accessToken: $0) }
    }

    /// Expanded instances in a time window (`singleEvents=true`).
    public static func windowRequest(calendarId: String, from: Date, to: Date, pageToken: String?) -> Builder {
        { request("/calendars/\(pathSegment(calendarId))/events", [
            "singleEvents": "true", "timeMin": iso(from), "timeMax": iso(to), "maxResults": "2500",
            "pageToken": pageToken, "fields": "nextPageToken,items(\(eventFields))",
        ], accessToken: $0) }
    }

    /// The pass that establishes a change-stream token: every event, ids only, so it stays cheap.
    public static func tokenPassRequest(calendarId: String, pageToken: String?) -> Builder {
        { request("/calendars/\(pathSegment(calendarId))/events", [
            "singleEvents": "false", "maxResults": "2500", "pageToken": pageToken,
            "fields": "nextPageToken,nextSyncToken,items(id)",
        ], accessToken: $0) }
    }

    /// Changes since `syncToken`: single events, recurring masters and exceptions, deletions included.
    public static func changesRequest(calendarId: String, syncToken: String, pageToken: String?) -> Builder {
        { request("/calendars/\(pathSegment(calendarId))/events", [
            "syncToken": syncToken, "maxResults": "2500", "pageToken": pageToken,
            "fields": "nextPageToken,nextSyncToken,items(\(eventFields))",
        ], accessToken: $0) }
    }

    public static func instancesRequest(calendarId: String, eventId: String, from: Date, to: Date,
                                        pageToken: String?) -> Builder {
        { request("/calendars/\(pathSegment(calendarId))/events/\(pathSegment(eventId))/instances", [
            "timeMin": iso(from), "timeMax": iso(to), "maxResults": "2500", "pageToken": pageToken,
            "fields": "nextPageToken,items(\(eventFields))",
        ], accessToken: $0) }
    }

    /// Google's calendar visibility (§12).
    public static func setSelectedRequest(calendarId: String, selected: Bool) -> Builder {
        { request("/users/me/calendarList/\(pathSegment(calendarId))", ["fields": "id,selected"], method: "PATCH",
                  body: try? JSONSerialization.data(withJSONObject: ["selected": selected]), accessToken: $0) }
    }

    // ISO8601DateFormatter is thread-safe; building one per event made each sync page allocate thousands
    static let internetDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let internetDateFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso(_ date: Date) -> String { internetDate.string(from: date) }

    // MARK: Responses

    public static func checkStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 404: throw APIError.notFound
        case 410: throw APIError.syncTokenExpired
        default: throw APIError.http(status)
        }
    }

    public static func decode<T: Decodable>(_ type: T.Type, data: Data, status: Int) throws -> T {
        try checkStatus(status)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw APIError.malformedResponse }
    }

    public struct CalendarListPage: Decodable {
        struct Item: Decodable {
            var id: String
            var summary: String?
            var summaryOverride: String?
            var backgroundColor: String?
            var accessRole: String
            var selected: Bool?
            var primary: Bool?
        }
        public var nextPageToken: String?
        var items: [Item]?

        public func calendars(account: String) -> [CalendarInfo] {
            (items ?? []).map {
                CalendarInfo(account: account, id: $0.id, summary: $0.summaryOverride ?? $0.summary ?? $0.id,
                             backgroundColor: $0.backgroundColor ?? "#9A9A9A", accessRole: $0.accessRole,
                             selected: $0.selected ?? false, primary: $0.primary ?? false)
            }
        }
    }

    public struct ColorsResponse: Decodable {
        struct Pair: Decodable { var background: String }
        var event: [String: Pair]?

        public func colors(account: String) -> [EventColor] {
            (event ?? [:]).map { EventColor(account: account, colorId: $0.key, background: $0.value.background) }
        }
    }

    public struct EventsPage: Decodable {
        public var nextPageToken: String?
        public var nextSyncToken: String?
        public var items: [GoogleEvent]?
    }

    public struct GoogleEvent: Decodable {
        struct Time: Decodable { var dateTime: String?; var date: String? }
        struct Person: Decodable {
            var email: String?
            var displayName: String?
            var isSelf: Bool?
            var organizer: Bool?
            var optional: Bool?
            var responseStatus: String?

            enum CodingKeys: String, CodingKey {
                case email, displayName, organizer, optional, responseStatus
                case isSelf = "self"
            }
        }
        struct Conference: Decodable {
            struct EntryPoint: Decodable { var entryPointType: String?; var uri: String? }
            var entryPoints: [EntryPoint]?
        }

        public var id: String
        public var status: String?
        var summary: String?
        var location: String?
        var description: String?
        var start: Time?
        var end: Time?
        public var recurringEventId: String?
        public var recurrence: [String]?
        var transparency: String?
        var colorId: String?
        var hangoutLink: String?
        var conferenceData: Conference?
        var attendees: [Person]?
        var organizer: Person?
        var htmlLink: String?

        public var isCancelled: Bool { status == "cancelled" }
        /// A recurring series' master event.
        public var isRecurringMaster: Bool { recurrence != nil }

        /// nil for a cancelled event or one without usable times.
        public func instance(account: String, calendarId: String, calendar: Calendar = .current) -> EventInstance? {
            guard !isCancelled, let start, let end,
                  let (startDate, allDay) = Self.parse(start, calendar: calendar),
                  let (endDate, _) = Self.parse(end, calendar: calendar) else { return nil }
            let people = (attendees ?? []).compactMap { p -> Attendee? in
                guard let email = p.email else { return nil }
                return Attendee(email: email, displayName: p.displayName, isSelf: p.isSelf ?? false,
                                organizer: p.organizer ?? false, optional: p.optional ?? false,
                                responseStatus: p.responseStatus ?? "needsAction")
            }
            let video = conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
            return EventInstance(
                account: account, calendarId: calendarId, id: id, recurringEventId: recurringEventId,
                summary: summary ?? "(No title)", location: location, notes: description,
                start: startDate, end: endDate, allDay: allDay, transparency: transparency, colorId: colorId,
                conferenceURL: video ?? hangoutLink ?? ConferenceDetector.url(in: [location, description]),
                selfResponse: people.first(where: \.isSelf)?.responseStatus,
                organizerSelf: organizer?.isSelf ?? false, attendees: people, htmlLink: htmlLink)
        }

        static func parse(_ t: Time, calendar: Calendar) -> (Date, Bool)? {
            if let dt = t.dateTime {
                guard let d = GoogleCalendarAPI.internetDate.date(from: dt)
                        ?? GoogleCalendarAPI.internetDateFractional.date(from: dt) else { return nil }
                return (d, false)
            }
            if let day = t.date {
                // all-day dates are calendar days, not instants: midnight in the user's time zone
                let parts = day.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3 else { return nil }
                return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])).map { ($0, true) }
            }
            return nil
        }
    }
}

extension AccountStore {
    /// GETs (or sends) `build` for `email` and decodes the response, mapping 404/410 to `APIError`.
    public func calendarAPI<T: Decodable>(_ type: T.Type, for email: String,
                                          _ build: GoogleCalendarAPI.Builder) async throws -> T {
        let (data, status) = try await sendAuthorized(for: email, build)
        return try GoogleCalendarAPI.decode(T.self, data: data, status: status)
    }
}
