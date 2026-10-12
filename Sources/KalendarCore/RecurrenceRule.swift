// The repeat and repeat-end fields (§6.1): an RFC 5545 RRULE as the editor sees it.
//
// Kalendar edits frequency, interval, weekdays and the end. Any other RRULE part it reads
// (BYMONTHDAY, BYSETPOS, ordinal BYDAY like "1MO", …) is kept and written back unchanged, so
// editing an event made elsewhere never drops part of its rule.
import Foundation

public struct RecurrenceRule: Equatable, Hashable {
    public enum Frequency: String, CaseIterable, Hashable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"

        /// "Daily", for the Custom repeat frequency picker.
        public var adjective: String { unit == "day" ? "Daily" : unit.capitalized + "ly" }

        public var unit: String {
            switch self {
            case .daily: "day"
            case .weekly: "week"
            case .monthly: "month"
            case .yearly: "year"
            }
        }
    }

    public enum End: Equatable, Hashable {
        case never
        /// The last day on which an occurrence may start (inclusive).
        case until(Date)
        case count(Int)
    }

    public var frequency: Frequency
    public var interval: Int
    /// Weekdays for a weekly rule, 1 = Sunday … 7 = Saturday. Empty means "the start's weekday".
    public var weekdays: Set<Int>
    public var end: End
    /// RRULE parts Kalendar does not edit, "KEY=VALUE", in their original order.
    var otherParts: [String]

    public init(frequency: Frequency, interval: Int = 1, weekdays: Set<Int> = [], end: End = .never) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.end = end
        otherParts = []
    }

    private static let dayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    // MARK: Parsing and writing

    /// The first RRULE in a Google `recurrence` array.
    public init?(recurrence: [String]) {
        guard let line = recurrence.first(where: { $0.hasPrefix("RRULE:") }) else { return nil }
        self.init(rrule: line)
    }

    /// "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;UNTIL=20261231T075959Z"
    public init?(rrule: String) {
        let body = rrule.hasPrefix("RRULE:") ? String(rrule.dropFirst(6)) : rrule
        var frequency: Frequency?
        var interval = 1
        var weekdays = Set<Int>()
        var end = End.never
        var other: [String] = []
        for part in body.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "FREQ": frequency = Frequency(rawValue: kv[1])
            case "INTERVAL": interval = Int(kv[1]) ?? 1
            case "COUNT": end = Int(kv[1]).map(End.count) ?? .never
            case "UNTIL": end = Self.parseUntil(kv[1]).map(End.until) ?? .never
            case "BYDAY":
                let days = kv[1].split(separator: ",").map(String.init)
                // plain weekday codes only; "1MO" style ordinals stay as they were
                if days.allSatisfy({ Self.dayCodes.contains($0) }) {
                    weekdays = Set(days.compactMap { Self.dayCodes.firstIndex(of: $0).map { $0 + 1 } })
                } else {
                    other.append(String(part))
                }
            default: other.append(String(part))
            }
        }
        guard let frequency else { return nil }
        self.init(frequency: frequency, interval: interval, weekdays: weekdays, end: end)
        otherParts = other
    }

    /// The RRULE line. RFC 5545 wants UNTIL as a date for an all-day event, and for a timed event
    /// as a UTC time: the end of that day in `calendar`'s time zone.
    public func rrule(calendar: Calendar = .current, allDay: Bool = false) -> String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if !weekdays.isEmpty { parts.append("BYDAY=" + weekdays.sorted().map { Self.dayCodes[$0 - 1] }.joined(separator: ",")) }
        parts += otherParts
        switch end {
        case .never: break
        case .count(let n): parts.append("COUNT=\(n)")
        case .until(let day) where allDay:
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            parts.append(String(format: "UNTIL=%04d%02d%02d", c.year!, c.month!, c.day!))
        case .until(let day):
            let last = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: day))!
            parts.append("UNTIL=" + Self.untilFormatter.string(from: last))
        }
        return "RRULE:" + parts.joined(separator: ";")
    }

    /// `recurrence` with the RRULE replaced (or removed when `rule` is nil); EXDATE/RDATE lines stay.
    public static func replacing(_ rule: RecurrenceRule?, in recurrence: [String], allDay: Bool = false) -> [String] {
        let rest = recurrence.filter { !$0.hasPrefix("RRULE:") }
        return rule.map { [$0.rrule(allDay: allDay)] + rest } ?? rest
    }

    private static let untilFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static func parseUntil(_ value: String) -> Date? {
        if let d = untilFormatter.date(from: value) { return d }
        // a date-only UNTIL (all-day events) is a calendar day
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.date(from: value)
    }

    // MARK: Presets and summary

    public enum Preset: String, CaseIterable {
        case daily = "Every Day", weekly = "Every Week", monthly = "Every Month", yearly = "Every Year"

        public var rule: RecurrenceRule {
            RecurrenceRule(frequency: Frequency.allCases[Preset.allCases.firstIndex(of: self)!])
        }
    }

    /// The menu item this rule is, ignoring its end; nil when only "Custom…" describes it.
    public var preset: Preset? { preset(start: nil) }

    /// As `preset`, but a weekly rule on just the start's weekday also counts as Every Week: Google
    /// writes a plain weekly event as `FREQ=WEEKLY;BYDAY=MO`.
    public func preset(start: Date?, calendar: Calendar = .current) -> Preset? {
        guard interval == 1, otherParts.isEmpty else { return nil }
        let startDay = start.map { calendar.component(.weekday, from: $0) }
        guard weekdays.isEmpty || (frequency == .weekly && weekdays == Set([startDay].compactMap { $0 })) else { return nil }
        return Preset.allCases.first { $0.rule.frequency == frequency }
    }

    /// "Every Week", "Every 2 weeks on Monday and Wednesday",
    /// "Every week on Monday, Tuesday, Wednesday, Thursday and Friday" (§5.2).
    public func summary(start: Date? = nil, calendar: Calendar = .current) -> String {
        if let preset = preset(start: start, calendar: calendar) { return preset.rawValue }
        var text = interval == 1 ? "Every \(frequency.unit)" : "Every \(interval) \(frequency.unit)s"
        if !weekdays.isEmpty {
            let formatter = DateFormatter()   // full names; Calendar.weekdaySymbols can be abbreviated
            formatter.calendar = calendar
            let names = weekdays.sorted().map { formatter.weekdaySymbols[$0 - 1] }
            text += " on " + Self.list(names)
        }
        return text
    }

    /// "Never", "Until Dec 31, 2026", "After 5 times".
    public var endSummary: String {
        switch end {
        case .never: "Never"
        case .until(let day): "Until \(day.formatted(date: .abbreviated, time: .omitted))"
        case .count(let n): n == 1 ? "After 1 time" : "After \(n) times"
        }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
