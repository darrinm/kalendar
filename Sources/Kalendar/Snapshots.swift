// `-renderSnapshots <dir>`: renders the Mini Window in light and dark at each text size into PNGs,
// then quits. The variants are set on the rendered views, never in the user's settings. The window is a non-activating panel placed off every screen, so checking the UI
// never takes focus from the app the user is in.
import AppKit
import SwiftUI

@MainActor
enum Snapshots {
    static func render(model: PopoverModel, settings: (Int) -> SettingsView, to directory: String) {
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        model.willOpen()
        for appearance in [Preferences.Appearance.light, .dark] {
            for size in Preferences.TextSize.allCases {
                let file = url.appendingPathComponent("popover-\(appearance.rawValue.lowercased())-\(size.rawValue.lowercased()).png")
                write(PopoverRoot(model: model).environment(\.textScale, size.scale),
                      size: PopoverController.size(scale: size.scale), appearance: appearance, to: file)
            }
        }
        // states reached by typing and clicking; nothing here writes to Google
        let popover = { (name: String) in
            write(PopoverRoot(model: model), size: PopoverController.size(scale: 1), appearance: .dark,
                  to: url.appendingPathComponent("\(name).png"))
        }
        for (name, input) in [("new-event", "Lunch tomorrow noon at Tartine"), ("new-task", "todo buy milk tomorrow 3pm"),
                              ("suggest-contact", "Sync with Da"), ("suggest-calendar", "/")] {
            model.input = input
            popover(name)
        }
        model.input = ""
        model.agenda.showsTasks = true
        popover("tasks")
        model.agenda.showsTasks = false
        let agenda = model.agenda
        if let event = agenda.sections.lazy.flatMap(\.timed).first {
            write(EventEditor(model: EventEditorModel(event: event, agenda: agenda, writer: model.writer)).frame(width: 300),
                  size: NSSize(width: 300, height: 640), appearance: .dark, to: url.appendingPathComponent("event-detail.png"))
        }
        if let task = agenda.sections.lazy.flatMap(\.tasks).first {
            write(TaskEditor(model: TaskEditorModel(task: task, agenda: agenda, writer: model.writer)).frame(width: 300),
                  size: NSSize(width: 300, height: 300), appearance: .dark, to: url.appendingPathComponent("task-detail.png"))
        }
        for tab in 0..<SettingsView.tabCount {
            write(settings(tab), size: SettingsView.size, appearance: .dark,
                  to: url.appendingPathComponent("settings-\(tab).png"))
        }
        for (name, image) in [("date", StatusItemController.glyph(day: 12)),
                              ("icon-only", StatusItemController.glyph(day: nil)),
                              ("color", StatusItemController.glyph(day: 12, color: true))] {
            let big = NSImage(size: NSSize(width: 72, height: 64), flipped: false) { rect in
                image.draw(in: rect)
                return true
            }
            if let tiff = big.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("icon-\(name).png"))
            }
        }
        model.agenda.isVisible = false
    }

    private static func write(_ view: some View, size: NSSize, appearance: Preferences.Appearance, to file: URL) {
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = appearance.nsAppearance
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        // let SwiftUI lay out and draw
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        panel.orderOut(nil)
    }
}
