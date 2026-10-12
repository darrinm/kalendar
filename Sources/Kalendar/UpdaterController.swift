// In-app updates via Sparkle (§20). The appcast and the signed DMG are attached to each GitHub
// release of darrinm/kalendar.
//
// Every update is verified twice before it runs: Sparkle checks the EdDSA signature against
// SUPublicEDKey in Info.plist, and macOS checks the Developer ID signature and notarization.
import AppKit
import KalendarCore
import Sparkle

@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    /// nil in a build whose Info.plist carries no public key — a local build, where an updater
    /// would either refuse every update or accept an unsigned one.
    private let controller: SPUStandardUpdaterController?

    private static let releasesPage = URL(string: "https://github.com/darrinm/kalendar/releases/latest")!

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let key, !key.isEmpty else {
            Log.shell.info("updates disabled: no SUPublicEDKey in this build")
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        guard let controller else {
            NSWorkspace.shared.open(Self.releasesPage)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Set through Sparkle, not the SUEnableAutomaticChecks user default, so the change reschedules
    /// the running updater instead of waiting for the next launch.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates
              ?? (UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true) }
        set {
            if let controller { controller.updater.automaticallyChecksForUpdates = newValue }
            else { UserDefaults.standard.set(newValue, forKey: Self.automaticChecksKey) }
        }
    }

    private static let automaticChecksKey = "SUEnableAutomaticChecks"

    /// Menu validation: Sparkle refuses a check while one is already running.
    var canCheckNow: Bool { controller?.updater.canCheckForUpdates ?? true }
}
