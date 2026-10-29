import AppKit
import Sparkle

// Auto-updates through Sparkle. The feed (SUFeedURL) and the update-signing public
// key (SUPublicEDKey) are in Info.plist; updates are notarized DMGs on GitHub
// Releases, and the newest release carries the appcast.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    // Only a real app bundle with a feed can update itself (not `swift run`).
    static var isAvailable: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    func start() {
        guard Updater.isAvailable, controller == nil else {
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    // TinyHand lives in the menu bar, so a scheduled check that finds an update must
    // bring its window forward rather than open it behind other apps.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
