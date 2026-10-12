// Kalendar's colors (spec §14). The palette is the one from browser-driver-mcp's setup page:
// a #00AAFF blue accent on navy in dark mode and on near-white in light mode. Every color in the
// UI comes from here; views do not use literal colors or the system accent.
import AppKit
import SwiftUI

enum Theme {
    /// Buttons, today, the year in the month title, the selected weekday, the Join pill.
    static let accent = Color(nsColor: nsAccent)
    /// Accent-colored text on the background: links, and the accent where it is text-sized.
    static let accentInk = Color(light: 0x0077C2, dark: 0x66CCFF)
    /// Popover and window background.
    static let background = Color(nsColor: nsBackground)
    /// Raised surfaces inside the background: the new-item form, the detail popover's cards.
    static let card = Color(light: 0xFFFFFF, dark: 0x121A25)
    static let text = Color(light: 0x18202B, dark: 0xE6EDF5)
    static let muted = Color(light: 0x5C6878, dark: 0x93A2B5)
    static let line = Color(light: 0xE2E7EE, dark: 0x223042)
    /// Accepted.
    static let ok = Color(light: 0x16A34A, dark: 0x4ADE80)
    /// Tentative, overdue.
    static let wait = Color(light: 0xB7791F, dark: 0xF0B458)
    /// Declined, errors, the pending-invitation badge.
    static let bad = Color(light: 0xC0392B, dark: 0xF87171)

    static let nsBackground = NSColor(light: 0xF6F8FB, dark: 0x0B1119)
    static let nsAccent = NSColor(light: 0x00AAFF, dark: 0x33BBFF)
}

extension NSColor {
    /// A color that follows the light/dark appearance of whatever draws it.
    convenience init(light: UInt32, dark: UInt32) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(light: light, dark: dark))
    }
}
