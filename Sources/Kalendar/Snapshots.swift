// `-renderSnapshots <dir>`: renders the Mini Window in light and dark at each text size into PNGs,
// then quits. The window is a non-activating panel placed off every screen, so checking the UI
// never takes focus from the app the user is in.
import AppKit
import SwiftUI

@MainActor
enum Snapshots {
    static func render(model: PopoverModel, settings: (Int) -> SettingsView, to directory: String) {
        let prefs = Preferences.shared
        let saved = (prefs.textSize, prefs.appearance)
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        model.willOpen()
        for appearance in [Preferences.Appearance.light, .dark] {
            for size in Preferences.TextSize.allCases {
                prefs.textSize = size
                prefs.appearance = appearance
                let file = url.appendingPathComponent("popover-\(appearance.rawValue.lowercased())-\(size.rawValue.lowercased()).png")
                write(PopoverRoot(model: model), size: PopoverController.size, appearance: appearance, to: file)
            }
        }
        prefs.textSize = saved.0
        prefs.appearance = saved.1
        for tab in 0..<5 {
            write(settings(tab), size: NSSize(width: 520, height: 460), appearance: .dark,
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
        panel.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
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
