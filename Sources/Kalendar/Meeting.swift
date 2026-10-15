// Join (§4.3): every Join button, menu item and alert action opens a meeting link here, so the
// Open Zoom meetings in browser setting (§12) applies to all of them.
import AppKit
import KalendarCore

@MainActor
enum Meeting {
    static func join(_ url: URL) {
        NSWorkspace.shared.open(ConferenceDetector.joinURL(for: url, inBrowser: Preferences.shared.zoomInBrowser))
    }
}
