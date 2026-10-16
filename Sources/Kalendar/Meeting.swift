// Join (§4.3): every Join button, menu item and alert action opens a meeting link here, so the
// Open Zoom meetings in browser setting (§12) applies to all of them. Without it, a Zoom link opens
// the Zoom app directly when one is installed.
import AppKit
import KalendarCore

@MainActor
enum Meeting {
    static func join(_ url: URL) {
        let zoomApp = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "zoommtg://zoom.us")!) != nil
        NSWorkspace.shared.open(ConferenceDetector.joinURL(for: url, inBrowser: Preferences.shared.zoomInBrowser,
                                                           zoomApp: zoomApp))
    }
}
