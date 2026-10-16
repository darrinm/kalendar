// Finds an event's video-call link (§4.3) for the 📹 glyph, the Join pill, the menu bar's Join
// button and the alert's Join action. Google's structured conference data wins; otherwise links in
// the location and notes.
import Foundation

public enum ConferenceDetector {
    private static let patterns: [String] = [
        #"https?://[\w.-]*zoom\.us/(?:j|my|w)/[^\s<>"')]+"#,
        #"https?://meet\.google\.com/[a-z0-9-]+"#,
        #"https?://teams\.microsoft\.com/l/meetup-join/[^\s<>"')]+"#,
        #"https?://teams\.live\.com/meet/[^\s<>"')]+"#,
        #"https?://[\w.-]*webex\.com/(?:meet|join|[\w.-]+/j\.php)[^\s<>"')]*"#,
        #"https?://facetime\.apple\.com/join[^\s<>"')]*"#,
    ]
    private static let regexes = patterns.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// The first video link in `texts`, in order.
    public static func url(in texts: [String?]) -> String? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regexes.compactMap { $0.firstMatch(in: text, range: range) }
            if let first = matches.min(by: { $0.range.location < $1.range.location }),
               let r = Range(first.range, in: text) {
                return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            }
        }
        return nil
    }

    /// `text` without its video links and the separators they leave behind: "Room 4,
    /// https://zoom.us/j/1" is "Room 4". The 📹 glyph and Join already stand for the link.
    public static func removingLinks(from text: String) -> String {
        // most locations have no link; list rows call this on every render
        guard text.contains("://") else { return text }
        var out = text
        for regex in regexes {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        // a location with no link keeps its own punctuation
        guard out != text else { return text }
        let separators = CharacterSet(charactersIn: ",;·|").union(.whitespacesAndNewlines)
        return out.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: separators) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// "Zoom", "Google Meet", … for "Join Zoom Meeting" (§7.1).
    public static func serviceName(for url: String) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        if isZoomHost(host) { return "Zoom" }
        if host == "meet.google.com" { return "Google Meet" }
        if host.contains("teams.") { return "Teams" }
        if host.hasSuffix("webex.com") { return "Webex" }
        if host == "facetime.apple.com" { return "FaceTime" }
        return "Video"
    }

    /// Where Join sends a Zoom meeting link (§4.3).
    public enum ZoomJoin {
        /// the link as it is
        case asIs
        /// Zoom's web client, zoom.us/wc/<id>/join
        case webClient
        /// the Zoom app, zoommtg://zoom.us/join?action=join&confno=<id>, without Zoom's launcher page
        case app
    }

    /// The link Join opens (§4.3). A Zoom /j/<id> link is rewritten for `zoom`, keeping its query
    /// (the passcode). Any other link is returned unchanged.
    public static func joinURL(for url: URL, zoom: ZoomJoin) -> URL {
        guard zoom != .asIs, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              isZoomHost(parts.host?.lowercased() ?? "") else { return url }
        // exactly /j/<id>, with or without a trailing slash
        let segments = parts.path.split(separator: "/")
        guard segments.count == 2, segments[0].lowercased() == "j" else { return url }
        let id = segments[1]
        switch zoom {
        case .asIs:
            return url
        case .webClient:
            parts.path = "/wc/\(id)/join"
        case .app:
            // a meeting ID is digits; anything else would be invalid in the percent-encoded query
            guard id.allSatisfy({ ("0"..."9").contains($0) }) else { return url }
            parts.scheme = "zoommtg"
            parts.path = "/join"
            // percent-encoded items keep the passcode's encoding: a decoded %2B would go back as "+"
            parts.percentEncodedQueryItems = [URLQueryItem(name: "action", value: "join"),
                                              URLQueryItem(name: "confno", value: String(id))]
                + (parts.percentEncodedQueryItems ?? [])
            parts.fragment = nil
        }
        return parts.url ?? url
    }

    /// zoom.us or a subdomain of it (us02web.zoom.us), not a host that merely ends in "zoom.us".
    /// `host` is lowercased.
    private static func isZoomHost(_ host: String) -> Bool {
        host == "zoom.us" || host.hasSuffix(".zoom.us")
    }

    /// How long before its start a meeting is offered for Join.
    public static let joinLead: TimeInterval = 15 * 60

    /// The one event to offer Join for (§3, §4.3): timed, with a video link, not declined, in progress
    /// or starting within `joinLead`. With several, the one that started or starts last.
    public static func joinCandidate(in events: [EventInstance], now: Date) -> EventInstance? {
        events.filter {
            !$0.allDay && !$0.isDeclined && $0.conferenceURL != nil
                && $0.end > now && $0.start <= now.addingTimeInterval(joinLead)
        }
        .max { $0.start < $1.start }
    }
}
