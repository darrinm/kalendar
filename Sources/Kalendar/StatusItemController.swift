// The menu bar item (§3, §12): a calendar glyph with today's day number, or the glyph alone, or
// the next event's title, with an optional countdown. Left-click toggles the popover; right-click
// (or ⌃-click) opens a small menu.
import AppKit
import KalendarCore

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let onToggle: () -> Void
    private let menu: NSMenu
    /// The next event today, for the next-event icon styles.
    var nextEvent: () -> EventInstance? = { nil }
    private var minuteTimer: Timer?

    var button: NSStatusBarButton? { item.button }

    init(onToggle: @escaping () -> Void, menu: NSMenu) {
        self.onToggle = onToggle
        self.menu = menu
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        redraw()
        // the countdown and the next event move on each minute, so the timer fires on the minute
        let nextMinute = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0),
                                                   matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        let timer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
        // the day number changes at midnight, when the clock or time zone changes, and across sleep
        let centers: [(NotificationCenter, Notification.Name)] = [
            (.default, .NSCalendarDayChanged), (.default, .NSSystemClockDidChange),
            (.default, .NSSystemTimeZoneDidChange), (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ]
        for (center, name) in centers {
            // queue: .main because NSCalendarDayChanged is posted on an arbitrary thread
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.redraw() }
            }
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // assigning the menu for one click and clearing it keeps left-click free for the popover
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            onToggle()
        }
    }

    /// Draws the item for the current settings, date and next event.
    func redraw() {
        guard let button = item.button else { return }
        let prefs = Preferences.shared
        let now = Date()
        let day = Calendar.current.component(.day, from: now)
        button.image = Self.glyph(day: prefs.iconStyle == .iconOnly ? nil : day, color: prefs.colorIcon)
        var label = "Kalendar, \(now.formatted(date: .complete, time: .omitted))"
        if prefs.iconStyle == .nextTitle || prefs.iconStyle == .nextCountdown, let next = nextEvent() {
            let text = Self.title(for: next, countdown: prefs.iconStyle == .nextCountdown, now: now)
            button.title = " " + text
            button.imagePosition = .imageLeading
            label += ", next: \(text)"
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
        button.setAccessibilityLabel(label)
    }

    /// "Standup" or "Standup in 25m" / "Standup now"; long titles are cut to fit the menu bar.
    static func title(for event: EventInstance, countdown: Bool, now: Date) -> String {
        let name = event.summary.count > 24 ? event.summary.prefix(23) + "…" : event.summary
        guard countdown else { return name }
        let minutes = Int(ceil(event.start.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "\(name) now" }
        return minutes < 60 ? "\(name) in \(minutes)m" : "\(name) in \(minutes / 60)h \(minutes % 60)m"
    }

    /// An outlined calendar page with a solid header bar and the day number (none for "Icon only").
    /// A template image, so the menu bar tints it, unless "Use color icon" draws the header in the
    /// accent.
    static func glyph(day: Int?, color: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        // a template is tinted by the menu bar; a color icon draws its outline in the label color
        let ink: NSColor = color ? .labelColor : .black
        let image = NSImage(size: size, flipped: false) { rect in
            let page = rect.insetBy(dx: 1, dy: 0.75)
            let outline = NSBezierPath(roundedRect: page, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.25
            ink.setStroke()
            outline.stroke()
            // header bar along the top edge
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            (color ? Theme.nsAccent : NSColor.black).setFill()
            NSRect(x: page.minX, y: page.maxY - 3.5, width: page.width, height: 3.5).fill()
            NSGraphicsContext.restoreGraphicsState()

            guard let day else { return true }
            let text = "\(day)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: ink,
            ]
            let textSize = text.size(withAttributes: attrs)
            let body = NSRect(x: page.minX, y: page.minY, width: page.width, height: page.height - 3.5)
            text.draw(at: NSPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2 - 0.25),
                      withAttributes: attrs)
            return true
        }
        image.isTemplate = !color
        return image
    }
}
