// The menu bar item: a template calendar glyph showing today's day number (§3).
// Left-click toggles the popover; right-click (or ⌃-click) opens a small menu.
import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onToggle: () -> Void
    private let menu: NSMenu

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

    private func redraw() {
        let day = Calendar.current.component(.day, from: Date())
        item.button?.image = Self.glyph(day: day)
        item.button?.setAccessibilityLabel("Kalendar, \(Date().formatted(date: .complete, time: .omitted))")
    }

    /// An outlined calendar page with a solid header bar and the day number, drawn as a template
    /// image so the menu bar tints it for light, dark and selected states.
    static func glyph(day: Int) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let page = rect.insetBy(dx: 1, dy: 0.75)
            let outline = NSBezierPath(roundedRect: page, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.25
            NSColor.black.setStroke()
            outline.stroke()
            // header bar along the top edge
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NSColor.black.setFill()
            NSRect(x: page.minX, y: page.maxY - 3.5, width: page.width, height: 3.5).fill()
            NSGraphicsContext.restoreGraphicsState()

            let text = "\(day)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: NSColor.black,
            ]
            let textSize = text.size(withAttributes: attrs)
            let body = NSRect(x: page.minX, y: page.minY, width: page.width, height: page.height - 3.5)
            text.draw(at: NSPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2 - 0.25),
                      withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }
}
