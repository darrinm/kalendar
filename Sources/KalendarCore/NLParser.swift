// Natural-language entry (§5.2, §5.3): "Lunch with Sam tomorrow at noon at Tartine alert 15 min".
//
// A hand-written tokenizer and rule parser: deterministic, offline, instant on every keystroke.
// Rules run left to right; each one that matches consumes its tokens. Whatever no rule consumes
// is the title. A second pass reads `at <place>` and `with <person>`, whose words run until the
// next consumed token, so "at Tartine tomorrow" stops before "tomorrow".
import Foundation

public struct ParsedItem: Equatable {
    public var title = ""
    public var location: String?
    /// A `todo` / `task` / `reminder` / `√` prefix (§5.1).
    public var isTask = false
    public var allDay = true
    public var start: Date
    /// Exclusive, like Google's.
    public var end: Date
    /// Whether the text named a date (a task's "due" checkbox, §5.1).
    public var hasDate = false
    public var recurrence: RecurrenceRule?
    /// Minutes before the start; empty means the calendar's defaults (or none for all-day).
    public var alerts: [Int] = []
    /// The text after a `/` token: a calendar name prefix.
    public var calendarQuery: String?
    /// Emails of `with` people the contact matcher recognized.
    public var invitees: [String] = []
    /// The token being typed, when it should show a suggestion list.
    public var trigger: SuggestionTrigger?
}

public struct SuggestionTrigger: Equatable {
    public enum Kind: Equatable { case calendar, contact, location }
    public var kind: Kind
    public var query: String
    /// The text the suggestion replaces when accepted, including its `/`, `with` or `at`.
    public var range: Range<String.Index>
}

public struct NLParser {
    public var now: Date
    public var calendar: Calendar
    public var defaultDuration: TimeInterval
    /// A day to use when the text names none (double-clicking a day, §4.2).
    public var defaultDay: Date?
    /// Returns an email when a `with` name matches a contact (§5.2: an unmatched name stays in the title).
    public var contactMatcher: (String) -> String?

    public init(now: Date = Date(), calendar: Calendar = .current, defaultDuration: TimeInterval = 3600,
                defaultDay: Date? = nil, contactMatcher: @escaping (String) -> String? = { _ in nil }) {
        self.now = now
        self.calendar = calendar
        self.defaultDuration = defaultDuration
        self.defaultDay = defaultDay
        self.contactMatcher = contactMatcher
    }

    // MARK: Tokens

    struct Token {
        var text: String
        /// Lowercased, without trailing punctuation.
        var word: String
        var range: Range<String.Index>
        var quoted = false
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace {
                i = text.index(after: i)
                continue
            }
            if text[i] == "\"" {
                // a quoted literal is one token, never parsed (§5.2)
                let close = text[text.index(after: i)...].firstIndex(of: "\"") ?? text.endIndex
                let end = close < text.endIndex ? text.index(after: close) : close
                let inner = String(text[text.index(after: i)..<close])
                tokens.append(Token(text: inner, word: inner.lowercased(), range: i..<end, quoted: true))
                i = end
                continue
            }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            let raw = String(text[i..<j])
            let word = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;!?"))
            tokens.append(Token(text: raw, word: word, range: i..<j))
            i = j
        }
        return tokens
    }

    // MARK: Parsing

    private struct State {
        var tokens: [Token]
        var consumed: [Bool]

        init(tokens: [Token]) {
            self.tokens = tokens
            consumed = Array(repeating: false, count: tokens.count)
        }

        var day: Date?
        var rangeEnd: Date?
        var time: (h: Int, m: Int)?
        var endTime: (h: Int, m: Int)?
        var duration: TimeInterval?
        var allDayWords = false
        var evening = false
        var recurrence: RecurrenceRule?
        var untilDate: Date?
        var count: Int?
        var alerts: [Int] = []
        var alertAt: [(h: Int, m: Int)] = []

        mutating func consume(_ i: Int, _ n: Int) { for k in i..<min(i + n, tokens.count) { consumed[k] = true } }
        func word(_ i: Int) -> String? { i < tokens.count && !tokens[i].quoted ? tokens[i].word : nil }
    }

    public func parse(_ text: String) -> ParsedItem {
        var s = State(tokens: Self.tokenize(text))
        var item = ParsedItem(start: now, end: now)

        if let first = s.word(0), ["todo", "task", "reminder", "√", "todo:", "task:", "reminder:"].contains(first) {
            item.isTask = true
            s.consume(0, 1)
        }

        var i = 0
        while i < s.tokens.count {
            if s.consumed[i] || s.tokens[i].quoted {
                i += 1
                continue
            }
            let n = match(&s, at: i, item: &item)
            i += max(n, 1)
        }

        readPlacesAndPeople(&s, item: &item, text: text)
        assemble(s, into: &item)
        item.title = s.tokens.indices.filter { !s.consumed[$0] }.map { s.tokens[$0].text }.joined(separator: " ")
        item.title = item.title.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        return item
    }

    /// Tries every rule at token `i`; returns how many tokens the matching rule consumed (0: none).
    private func match(_ s: inout State, at i: Int, item: inout ParsedItem) -> Int {
        let w = s.word(i) ?? ""

        if s.tokens[i].text.hasPrefix("/") {
            item.calendarQuery = String(s.tokens[i].text.dropFirst())
            s.consume(i, 1)
            return 1
        }
        if w == "all-day" || w == "allday" || (w == "all" && s.word(i + 1) == "day") {
            let n = w == "all" ? 2 : 1
            s.allDayWords = true
            s.consume(i, n)
            return n
        }
        if w == "alert" || w == "remind" {
            if let n = alert(&s, at: i) { return n }
        }
        if w == "every" {
            if let n = recurrence(&s, at: i + 1) { s.consume(i, n + 1); return n + 1 }
        }
        if let (days, n) = pluralWeekdays(s, at: i) {
            // "mondays and wednesdays" (§5.3)
            s.recurrence = RecurrenceRule(frequency: .weekly, weekdays: days)
            s.consume(i, n)
            return n
        }
        if w == "until", s.recurrence != nil || s.day != nil, let (date, n) = date(s, at: i + 1) {
            if s.recurrence != nil { s.untilDate = date } else { s.rangeEnd = date }
            s.consume(i, n + 1)
            return n + 1
        }
        if w == "for" {
            if let n = forPhrase(&s, at: i + 1) { s.consume(i, n + 1); return n + 1 }
        }
        if w == "from" || w == "between" {
            if let n = rangePhrase(&s, at: i + 1) { s.consume(i, n + 1); return n + 1 }
        }
        if w == "at" || w == "on" || w == "@" {
            // "at 3pm", "on Friday"; "at Tartine" is a place, read in the second pass
            if s.time == nil, let (t, n) = time(s, at: i + 1, bareNumbers: true) {
                s.time = t
                s.consume(i, n + 1)
                return n + 1
            }
            if s.day == nil, let (d, n) = date(s, at: i + 1) {
                s.day = d
                s.consume(i, n + 1)
                return n + 1
            }
            return 0
        }
        if let n = rangePhrase(&s, at: i) { return n }
        if s.day == nil, let (d, n) = date(s, at: i) {
            s.day = d
            if w == "tonight" { s.evening = true }
            s.consume(i, n)
            return n
        }
        if s.time == nil, let (t, n) = time(s, at: i, bareNumbers: false) {
            s.time = t
            s.consume(i, n)
            return n
        }
        return 0
    }

    // MARK: Rules

    /// "alert 15 min", "alert 1 hour", "alert 2 days", "alert at 8am", "remind me 10 minutes before".
    private func alert(_ s: inout State, at i: Int) -> Int? {
        var j = i + 1
        if s.word(j) == "me" { j += 1 }
        if s.word(j) == "at", let (t, n) = time(s, at: j + 1, bareNumbers: true) {
            s.alertAt.append(t)
            s.consume(i, j + 1 + n - i)
            return j + 1 + n - i
        }
        guard let (minutes, n) = amount(s, at: j) else { return nil }
        var end = j + n
        if s.word(end) == "before" { end += 1 }
        s.alerts.append(minutes)
        s.consume(i, end - i)
        return end - i
    }

    /// "15 min", "15min", "1 hour", "2 days" → minutes, and the tokens used.
    private func amount(_ s: State, at i: Int) -> (Int, Int)? {
        guard let w = s.word(i) else { return nil }
        if let (value, unit) = Self.splitNumber(w), let u = unit, let m = Self.unitMinutes(u) {
            return (Int(value * Double(m)), 1)
        }
        guard let value = Double(w) ?? Self.numberWords[w], let unit = s.word(i + 1),
              let m = Self.unitMinutes(unit) else { return nil }
        return (Int(value * Double(m)), 2)
    }

    /// After "for": a duration ("for 15 minutes") or a repeat count ("for 10 times").
    private func forPhrase(_ s: inout State, at i: Int) -> Int? {
        if let w = s.word(i), let n = Self.integer(w), s.word(i + 1) == "times" {
            s.count = n
            return 2
        }
        guard let (minutes, n) = amount(s, at: i) else { return nil }
        s.duration = TimeInterval(minutes * 60)
        return n
    }

    /// After "every": "day", "weekday", "monday", "other week", "2 weeks", "monday and wednesday".
    private func recurrence(_ s: inout State, at i: Int) -> Int? {
        guard let w = s.word(i) else { return nil }
        var interval = 1
        var j = i
        if w == "other" {
            interval = 2
            j += 1
        } else if let n = Self.integer(w), n > 1 {
            interval = n
            j += 1
        }
        guard let unit = s.word(j) else { return nil }
        let frequencies: [String: RecurrenceRule.Frequency] = [
            "day": .daily, "days": .daily, "week": .weekly, "weeks": .weekly,
            "month": .monthly, "months": .monthly, "year": .yearly, "years": .yearly,
        ]
        if let f = frequencies[unit] {
            s.recurrence = RecurrenceRule(frequency: f, interval: interval)
            return j - i + 1
        }
        if unit == "weekday" || unit == "weekdays" {
            s.recurrence = RecurrenceRule(frequency: .weekly, interval: interval, weekdays: [2, 3, 4, 5, 6])
            return j - i + 1
        }
        if unit == "weekend" || unit == "weekends" {
            s.recurrence = RecurrenceRule(frequency: .weekly, interval: interval, weekdays: [1, 7])
            return j - i + 1
        }
        guard let (days, n) = weekdayList(s, at: j) else { return nil }
        s.recurrence = RecurrenceRule(frequency: .weekly, interval: interval, weekdays: days)
        return j - i + n
    }

    /// "monday", "mon and wed", "tuesday, thursday" → weekdays and tokens used.
    private func weekdayList(_ s: State, at i: Int) -> (Set<Int>, Int)? {
        guard let first = s.word(i).flatMap(Self.weekday) else { return nil }
        var days: Set<Int> = [first]
        var j = i + 1
        while let w = s.word(j) {
            let next = (w == "and" || w == "&") ? j + 1 : j
            guard let d = s.word(next).flatMap(Self.weekday) else { break }
            days.insert(d)
            j = next + 1
        }
        return (days, j - i)
    }

    /// "mondays", "mondays and wednesdays" (plural only, so a lone "monday" stays a date).
    private func pluralWeekdays(_ s: State, at i: Int) -> (Set<Int>, Int)? {
        guard let w = s.word(i), w.hasSuffix("s"), w.count > 3, let d = Self.weekday(String(w.dropLast())) else { return nil }
        var days: Set<Int> = [d]
        var j = i + 1
        while let next = s.word(j), next == "and" || next == "&",
              let plural = s.word(j + 1), plural.hasSuffix("s"), let e = Self.weekday(String(plural.dropLast())) {
            days.insert(e)
            j += 2
        }
        return (days, j - i)
    }

    /// Time ranges ("3-4pm", "3pm to 4pm", "from 3 to 4") and date ranges ("Aug 9-18",
    /// "Aug 9 to Aug 18"). At `i` the range itself starts (after any "from").
    private func rangePhrase(_ s: inout State, at i: Int) -> Int? {
        // "3-4pm", "3pm-4:30pm" in one token
        if let w = s.word(i), let dash = w.firstIndex(of: "-"), !w.contains("/"), Self.monthNumber(w) == nil {
            let a = String(w[..<dash]), b = String(w[w.index(after: dash)...])
            if let end = Self.clock(b, bareNumbers: true), let start = Self.clock(a, bareNumbers: true, meridiemOf: b) {
                s.time = start
                s.endTime = end
                s.consume(i, 1)
                return 1
            }
        }
        // <time> to|until|- <time>
        if let (t1, n1) = time(s, at: i, bareNumbers: true), let sep = s.word(i + n1), ["to", "until", "-", "–"].contains(sep),
           let (t2, n2) = time(s, at: i + n1 + 1, bareNumbers: true) {
            // the start borrows the end's am/pm when it has none: "3 to 4pm", "3 to 4 pm"
            let endText = s.tokens[(i + n1 + 1)..<(i + n1 + 1 + n2)].map(\.word).joined()
            s.time = n1 == 1 ? Self.clock(s.word(i)!, bareNumbers: true, meridiemOf: endText) ?? t1 : t1
            s.endTime = t2
            s.consume(i, n1 + 1 + n2)
            return n1 + 1 + n2
        }
        // <month> <d>-<d>
        if let month = s.word(i).flatMap(Self.monthNumber), let w = s.word(i + 1), let dash = w.firstIndex(of: "-"),
           let d1 = Int(w[..<dash].filter(\.isNumber)), let d2 = Int(w[w.index(after: dash)...].filter(\.isNumber)),
           let start = dayDate(month: month, day: d1, year: nil), let end = dayDate(month: month, day: d2, year: nil) {
            s.day = start
            s.rangeEnd = wrapYear(end, after: start)
            s.consume(i, 2)
            return 2
        }
        // <date> to|until|- <date>
        if let (d1, n1) = date(s, at: i), let sep = s.word(i + n1), ["to", "until", "-", "–", "through", "thru"].contains(sep),
           let (d2, n2) = date(s, at: i + n1 + 1) {
            s.day = d1
            s.rangeEnd = wrapYear(d2, after: d1)
            s.consume(i, n1 + 1 + n2)
            return n1 + 1 + n2
        }
        return nil
    }

    /// A clock time at `i`: "3pm", "3:15 pm", "15:00", "noon", "midnight"; bare "3" only after
    /// "at"/"from"/"to", where it means the afternoon for 1–7 (§5.3).
    private func time(_ s: State, at i: Int, bareNumbers: Bool) -> ((h: Int, m: Int), Int)? {
        guard let w = s.word(i) else { return nil }
        if let next = s.word(i + 1), ["am", "pm", "a.m", "p.m", "a", "p"].contains(next),
           let t = Self.clock(w + next.replacingOccurrences(of: ".", with: ""), bareNumbers: true) {
            return (t, 2)
        }
        return Self.clock(w, bareNumbers: bareNumbers).map { ($0, 1) }
    }

    /// A date at `i`: today, tomorrow, tonight, (next) weekday, "Oct 12", "October 12th, 2026",
    /// "12 Oct", "10/12", "10/12/2026".
    private func date(_ s: State, at i: Int) -> (Date, Int)? {
        guard let w = s.word(i) else { return nil }
        let today = calendar.startOfDay(for: now)
        switch w {
        case "today", "tonight": return (today, 1)
        case "tomorrow", "tmrw", "tmr": return (calendar.date(byAdding: .day, value: 1, to: today)!, 1)
        case "yesterday": return (calendar.date(byAdding: .day, value: -1, to: today)!, 1)
        default: break
        }
        if (w == "next" || w == "this"), let d = s.word(i + 1).flatMap(Self.weekday) {
            return (w == "next" ? nextWeek(weekday: d) : coming(weekday: d), 2)
        }
        // "in the sun", "a sat phone": an abbreviation that is also an English word is a date only
        // when it doesn't follow an article or "in"/"my"
        if Self.ambiguous.contains(w), i > 0, let before = s.word(i - 1), ["the", "a", "an", "in", "my"].contains(before) {
            return nil
        }
        if let d = Self.weekday(w) { return (coming(weekday: d), 1) }
        if let month = Self.monthNumber(w), let dayWord = s.word(i + 1), let day = Self.dayNumber(dayWord) {
            if let yw = s.word(i + 2), let year = Int(yw), year > 1900, let d = dayDate(month: month, day: day, year: year) {
                return (d, 3)
            }
            return dayDate(month: month, day: day, year: nil).map { ($0, 2) }
        }
        if let day = Self.dayNumber(w), let month = s.word(i + 1).flatMap(Self.monthNumber) {
            return dayDate(month: month, day: day, year: nil).map { ($0, 2) }
        }
        let parts = w.split(separator: "/").compactMap { Int($0) }
        if parts.count >= 2, w.split(separator: "/").count == parts.count {
            var year = parts.count > 2 ? parts[2] : nil
            if let y = year, y < 100 { year = 2000 + y }
            return dayDate(month: parts[0], day: parts[1], year: year).map { ($0, 1) }
        }
        return nil
    }

    // MARK: Second pass: places and people

    private static let connectors: Set<String> = ["at", "with", "on", "from", "for", "every", "alert", "until", "to", "@"]

    private func readPlacesAndPeople(_ s: inout State, item: inout ParsedItem, text: String) {
        var i = 0
        while i < s.tokens.count {
            guard !s.consumed[i], let w = s.word(i), w == "at" || w == "@" || w == "with" else {
                i += 1
                continue
            }
            var j = i + 1
            while j < s.tokens.count, !s.consumed[j], !s.tokens[j].quoted, !Self.connectors.contains(s.tokens[j].word) {
                j += 1
            }
            let words = s.tokens[(i + 1)..<j].map(\.text)
            let reachesEnd = j == s.tokens.count && !(text.last?.isWhitespace ?? false)
            if w == "with" {
                if reachesEnd {
                    item.trigger = SuggestionTrigger(kind: .contact, query: words.joined(separator: " "),
                                                     range: s.tokens[i].range.lowerBound..<text.endIndex)
                }
                if !words.isEmpty, let email = contactMatcher(words.joined(separator: " ")) {
                    item.invitees.append(email)
                    s.consume(i, j - i)
                }
            } else if !words.isEmpty {
                item.location = words.joined(separator: " ")
                s.consume(i, j - i)
                if reachesEnd {
                    item.trigger = SuggestionTrigger(kind: .location, query: item.location!,
                                                     range: s.tokens[i].range.lowerBound..<text.endIndex)
                }
            }
            i = j
        }
        if let last = s.tokens.last, last.text.hasPrefix("/"), !(text.last?.isWhitespace ?? false) {
            item.trigger = SuggestionTrigger(kind: .calendar, query: String(last.text.dropFirst()), range: last.range)
        }
    }

    // MARK: Assembly

    private func assemble(_ s: State, into item: inout ParsedItem) {
        let today = calendar.startOfDay(for: now)
        var recurrence = s.recurrence
        if var r = recurrence {
            if let until = s.untilDate { r.end = .until(until) } else if let n = s.count { r.end = .count(n) }
            recurrence = r
        }
        item.recurrence = recurrence
        item.hasDate = s.day != nil

        var day = s.day ?? defaultDay.map(calendar.startOfDay(for:)) ?? today
        // a weekly rule with no date starts on its first matching day
        if s.day == nil, let r = recurrence, r.frequency == .weekly, !r.weekdays.isEmpty {
            day = r.weekdays.map { coming(weekday: $0, from: day) }.min()!
        }

        var time = s.time
        if time == nil && s.evening { time = (19, 0) }
        if let t = time, !s.allDayWords {
            item.allDay = false
            var start = calendar.date(bySettingHour: t.h, minute: t.m, second: 0, of: day)!
            // a time alone that already passed today means tomorrow
            if s.day == nil, defaultDay == nil, recurrence == nil, start < now {
                start = calendar.date(byAdding: .day, value: 1, to: start)!
            }
            item.start = start
            if let e = s.endTime {
                var end = calendar.date(bySettingHour: e.h, minute: e.m, second: 0, of: start)!
                if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end)! }
                item.end = end
            } else {
                item.end = start.addingTimeInterval(s.duration ?? defaultDuration)
            }
            item.alerts = s.alerts + s.alertAt.compactMap { a in
                let at = calendar.date(bySettingHour: a.h, minute: a.m, second: 0, of: start)!
                let minutes = Int(start.timeIntervalSince(at) / 60)
                return minutes >= 0 ? minutes : nil
            }
        } else {
            item.allDay = true
            item.start = day
            let last = s.rangeEnd.map { max($0, day) } ?? day
            item.end = calendar.date(byAdding: .day, value: 1, to: last)!
            item.alerts = s.alerts
        }
    }

    // MARK: Dates

    /// The next day with this weekday, `from` (default today) included.
    private func coming(weekday: Int, from: Date? = nil) -> Date {
        let start = calendar.startOfDay(for: from ?? now)
        let ahead = (weekday - calendar.component(.weekday, from: start) + 7) % 7
        return calendar.date(byAdding: .day, value: ahead, to: start)!
    }

    /// The end of a range that came out before its start ("Dec 28 to Jan 3") is next year.
    private func wrapYear(_ end: Date, after start: Date) -> Date {
        end < start ? calendar.date(byAdding: .year, value: 1, to: end)! : end
    }

    /// That weekday in next week (weeks start on the calendar's first weekday).
    private func nextWeek(weekday: Int) -> Date {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let nextStart = calendar.date(byAdding: .day, value: 7, to: thisWeek)!
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: offset, to: nextStart)!
    }

    /// A month and day without a year means the next time that date comes around.
    private func dayDate(month: Int, day: Int, year: Int?) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let today = calendar.startOfDay(for: now)
        var c = DateComponents(year: year ?? calendar.component(.year, from: today), month: month, day: day)
        guard var date = calendar.date(from: c), calendar.component(.day, from: date) == day else { return nil }
        if year == nil, date < today {
            c.year! += 1
            date = calendar.date(from: c) ?? date
        }
        return date
    }

    // MARK: Words

    static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "half": 0.5,
    ]

    /// "3" or "three".
    static func integer(_ w: String) -> Int? { Int(w) ?? numberWords[w].map(Int.init) }

    static func unitMinutes(_ unit: String) -> Int? {
        switch unit {
        case "m", "min", "mins", "minute", "minutes": 1
        case "h", "hr", "hrs", "hour", "hours": 60
        case "d", "day", "days": 1440
        case "w", "wk", "week", "weeks": 10080
        default: nil
        }
    }

    /// "15min" → (15, "min"); "15" → (15, nil).
    static func splitNumber(_ w: String) -> (Double, String?)? {
        let digits = w.prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        let rest = String(w.dropFirst(digits.count))
        return (value, rest.isEmpty ? nil : rest)
    }

    private static let weekdayNames: [(String, Int)] = [
        ("sunday", 1), ("sun", 1), ("monday", 2), ("mon", 2), ("tuesday", 3), ("tues", 3), ("tue", 3),
        ("wednesday", 4), ("wed", 4), ("thursday", 5), ("thurs", 5), ("thur", 5), ("thu", 5),
        ("friday", 6), ("fri", 6), ("saturday", 7), ("sat", 7),
    ]

    static func weekday(_ w: String) -> Int? { weekdayNames.first { $0.0 == w }?.1 }

    /// Weekday and month abbreviations that are also common words.
    private static let ambiguous: Set<String> = ["sun", "sat", "wed", "mon", "may", "mar"]

    private static let fullMonthNames = ["january", "february", "march", "april", "may", "june", "july", "august",
                                         "september", "october", "november", "december"]
    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func monthNumber(_ w: String) -> Int? {
        guard w.count >= 3, w.allSatisfy(\.isLetter) else { return nil }
        if let i = fullMonthNames.firstIndex(of: w) { return i + 1 }
        if w == "sept" { return 9 }
        return monthNames.firstIndex(of: w).map { $0 + 1 }
    }

    /// "12", "12th", "1st".
    static func dayNumber(_ w: String) -> Int? {
        let digits = w.prefix(while: \.isNumber)
        guard !digits.isEmpty, let n = Int(digits), (1...31).contains(n) else { return nil }
        let rest = w.dropFirst(digits.count)
        return rest.isEmpty || ["st", "nd", "rd", "th"].contains(rest) ? n : nil
    }

    /// A clock reading. `meridiemOf` lends "pm" from the other end of a range ("3-4pm").
    static func clock(_ w: String, bareNumbers: Bool, meridiemOf other: String? = nil) -> (h: Int, m: Int)? {
        switch w {
        case "noon", "midday": return (12, 0)
        case "midnight": return (0, 0)
        default: break
        }
        var body = w
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where body.hasSuffix(suffix) && body.count > suffix.count {
            meridiem = String(suffix.prefix(1))
            body = String(body.dropLast(suffix.count))
            break
        }
        let parts = body.split(separator: ":")
        guard (1...2).contains(parts.count), let h = Int(parts[0]), parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let m = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
        guard (0...59).contains(m) else { return nil }
        if meridiem == nil, let other, let o = other.last, o == "m" || o == "a" || o == "p" {
            let lent = other.hasSuffix("am") || other.hasSuffix("a") ? "a" : "p"
            // "11-1pm" starts in the morning
            meridiem = (lent == "p" && h < 12 && h > (Int(other.prefix(while: \.isNumber)) ?? 12)) ? "a" : lent
        }
        if let meridiem {
            guard (1...12).contains(h) else { return nil }
            return (meridiem == "p" ? (h % 12) + 12 : h % 12, m)
        }
        if parts.count == 2 { return (0...23).contains(h) ? (h, m) : nil }   // "15:00"
        guard bareNumbers, (1...12).contains(h) else { return nil }
        return ((1...7).contains(h) ? h + 12 : h, 0)   // "at 3" is the afternoon
    }
}
