// Every setting (§12), observable by views and backed by UserDefaults. Defaults are the values
// observed in the reference app (§2).
import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    enum IconStyle: String, CaseIterable {
        case iconOnly = "Icon only", date = "Date", nextTitle = "Next event title", nextCountdown = "Next event + countdown"
    }
    /// The video conferencing a new event starts with (§5.1, §12).
    enum Video: String, CaseIterable {
        case none = "None", googleMeet = "Google Meet", zoom = "Zoom"
    }
    enum TextSize: String, CaseIterable {
        case small = "Small", normal = "Normal", large = "Large"
        var scale: CGFloat { switch self { case .small: 0.9; case .normal: 1; case .large: 1.15 } }
    }
    enum Appearance: String, CaseIterable {
        case system = "System", light = "Light", dark = "Dark"
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// The global shortcut (§11): a virtual key code and Carbon modifier flags.
    struct Hotkey: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        static let standard = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any setting changes.
    /// Called after a setting changes, with its UserDefaults key. Views observe the properties
    /// themselves; this is for the AppKit side and the cached agenda.
    @ObservationIgnored var onChange: (String) -> Void = { _ in }

    // General
    var hotkey: Hotkey {
        didSet {
            defaults.set(hotkey.keyCode, forKey: "hotkeyKeyCode")
            defaults.set(hotkey.modifiers, forKey: "hotkeyModifiers")
            onChange("hotkey")
        }
    }
    /// A `CalendarInfo.key`; nil uses the first account's primary calendar.
    var defaultCalendar: String? { didSet { save(defaultCalendar, "defaultCalendar") } }
    /// A `TaskList.key`; nil uses the first account's first list.
    var defaultTaskList: String? { didSet { save(defaultTaskList, "defaultTaskList") } }
    /// Minutes.
    var defaultDuration: Int { didSet { save(defaultDuration, "defaultDuration") } }
    /// 1 = Sunday … 7 = Saturday; 0 follows the system.
    var firstWeekday: Int {
        didSet {
            calendar = Self.calendar(firstWeekday: firstWeekday)
            save(firstWeekday, "firstWeekday")
        }
    }
    /// The hour a new timed slot starts at when the input names no time.
    var dayStartHour: Int { didSet { save(dayStartHour, "dayStartHour") } }
    var playSounds: Bool { didSet { save(playSounds, "playSounds") } }
    var goToTodayAfterAdding: Bool { didSet { save(goToTodayAfterAdding, "goToTodayAfterAdding") } }
    var showAlerts: Bool { didSet { save(showAlerts, "showAlerts") } }
    var defaultVideo: Video { didSet { save(defaultVideo.rawValue, "defaultVideo") } }
    /// What a new event starts with: the default, except None while Zoom isn't connected.
    var newEventVideo: Video { defaultVideo == .zoom && !Zoom.account.isConnected ? .none : defaultVideo }
    /// Join opens Zoom meetings in the browser rather than the Zoom app.
    var zoomInBrowser: Bool { didSet { save(zoomInBrowser, "zoomInBrowser") } }

    // Appearance
    var iconStyle: IconStyle { didSet { save(iconStyle.rawValue, "iconStyle") } }
    var colorIcon: Bool { didSet { save(colorIcon, "colorIcon") } }
    var textSize: TextSize { didSet { save(textSize.rawValue, "textSize") } }
    var appearance: Appearance { didSet { save(appearance.rawValue, "appearance"); applyAppearance() } }

    // Events & Tasks
    /// Days the agenda list shows from the selected day; 0 is all days (scrolls without end).
    var listDays: Int { didSet { save(listDays, "listDays") } }
    var showEventEnds: Bool { didSet { save(showEventEnds, "showEventEnds") } }
    var showDeclined: Bool { didSet { save(showDeclined, "showDeclined") } }
    var combineIdentical: Bool { didSet { save(combineIdentical, "combineIdentical") } }
    var dimPast: Bool { didSet { save(dimPast, "dimPast") } }
    var showTasksInList: Bool { didSet { save(showTasksInList, "showTasksInList") } }
    var showCompletedTasks: Bool { didSet { save(showCompletedTasks, "showCompletedTasks") } }
    var taskSort: TaskSort { didSet { save(taskSort.rawValue, "taskSort") } }

    // Calendars
    /// `TaskList.key`s hidden from the agenda and the Tasks view; Google has no such flag.
    var hiddenTaskLists: Set<String> { didSet { save(Array(hiddenTaskLists).sorted(), "hiddenTaskLists") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: key) as? T ?? fallback }
        hotkey = defaults.object(forKey: "hotkeyKeyCode") == nil ? .standard
            : Hotkey(keyCode: UInt32(defaults.integer(forKey: "hotkeyKeyCode")),
                     modifiers: UInt32(defaults.integer(forKey: "hotkeyModifiers")))
        defaultCalendar = defaults.string(forKey: "defaultCalendar")
        defaultTaskList = defaults.string(forKey: "defaultTaskList")
        defaultDuration = value("defaultDuration", 60)
        let weekday = value("firstWeekday", 0)
        firstWeekday = weekday
        calendar = Self.calendar(firstWeekday: weekday)
        dayStartHour = value("dayStartHour", 8)
        playSounds = value("playSounds", true)
        goToTodayAfterAdding = value("goToTodayAfterAdding", true)
        showAlerts = value("showAlerts", true)
        defaultVideo = Video(rawValue: value("defaultVideo", "")) ?? .none
        zoomInBrowser = value("zoomInBrowser", false)
        iconStyle = IconStyle(rawValue: value("iconStyle", "")) ?? .date
        colorIcon = value("colorIcon", false)
        textSize = TextSize(rawValue: value("textSize", "")) ?? .normal
        appearance = Appearance(rawValue: value("appearance", "")) ?? .system
        listDays = value("listDays", 0)
        showEventEnds = value("showEventEnds", true)
        showDeclined = value("showDeclined", false)
        combineIdentical = value("combineIdentical", true)
        dimPast = value("dimPast", false)
        showTasksInList = value("showTasksInList", true)
        showCompletedTasks = value("showCompletedTasks", true)
        taskSort = TaskSort(rawValue: value("taskSort", "")) ?? .dueDate
        hiddenTaskLists = Set(value("hiddenTaskLists", [String]()))
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        onChange(key)
    }

    /// Theme (§12): Settings follows NSApp.appearance; the popover copies NSApp.effectiveAppearance
    /// (PopoverController), because a popover otherwise follows the menu bar.
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    /// The calendar the grid and the list use: the user's first weekday unless overridden. Built
    /// once per change, not per date computation.
    private(set) var calendar = Calendar.current

    private static func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar.current
        if firstWeekday != 0 { c.firstWeekday = firstWeekday }
        return c
    }

    /// The system's calendar, locale or time zone changed.
    func systemCalendarChanged() {
        calendar = Self.calendar(firstWeekday: firstWeekday)
    }
}

extension EnvironmentValues {
    /// The Text size setting's factor (§12), set at the root of the Mini Window and each popover.
    @Entry var textScale: CGFloat = 1
}

/// A system font at `size` points scaled by the environment's text scale.
private struct UIFont: ViewModifier {
    @Environment(\.textScale) private var scale
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: (size * scale).rounded(), weight: weight))
    }
}

extension View {
    func uiFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(UIFont(size: size, weight: weight))
    }
}
