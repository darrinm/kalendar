// Finds an event's video-call link (§4.3) for the 📹 glyph, the Join pill and the alert's Join
// action. Google's structured conference data wins; otherwise links in the location and notes.
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

    /// "Zoom", "Google Meet", … for "Join Zoom Meeting" (§7.1).
    public static func serviceName(for url: String) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        if host.hasSuffix("zoom.us") { return "Zoom" }
        if host == "meet.google.com" { return "Google Meet" }
        if host.contains("teams.") { return "Teams" }
        if host.hasSuffix("webex.com") { return "Webex" }
        if host == "facetime.apple.com" { return "FaceTime" }
        return "Video"
    }
}
