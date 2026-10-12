// Launch at login through SMAppService. On by default (§19: alerts are rescheduled only while
// Kalendar runs), so the first launch registers it once; after that the Settings toggle decides.
import KalendarCore
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    private static let initializedKey = "launchAtLoginInitialized"

    /// `.requiresApproval` counts as on: the app is registered and waits for the user to allow it
    /// in System Settings › Login Items.
    static var isEnabled: Bool { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.shell.error("launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    static func enableOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: initializedKey) else { return }
        defaults.set(true, forKey: initializedKey)
        // only a bundled app can register; `swift run` has no bundle to launch
        guard Bundle.main.bundleIdentifier != nil else { return }
        set(true)
    }
}
