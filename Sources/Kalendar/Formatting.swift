// Text formats from §4.3: section headers and time ranges.
import Foundation

enum Formatting {
    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Mdyy")
        return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    /// ("TODAY", "10/12/26"), ("TOMORROW", …), ("WEDNESDAY", …)
    static func header(for day: Date, today: Date, calendar: Calendar = .current) -> (String, String) {
        let label: String
        if calendar.isDate(day, inSameDayAs: today) {
            label = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(day, inSameDayAs: tomorrow) {
            label = "Tomorrow"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: yesterday) {
            label = "Yesterday"
        } else {
            label = weekday.string(from: day)
        }
        return (label.uppercased(), shortDate.string(from: day))
    }

    /// "9:00 – 10:00 AM", "11:30 AM – 12:30 PM": Foundation's interval style shows a shared AM/PM once.
    static func timeRange(_ start: Date, _ end: Date) -> String {
        (start..<max(start, end)).formatted(date: .omitted, time: .shortened)
    }
}
