import Cocoa

// In-app updates through Sparkle, in release builds only. `release/release.sh` links Sparkle.framework;
// `./build.sh` and `./test.sh` don't, so building from source needs nothing extra and simply has no updater.
// The feed (SUFeedURL), the public key (SUPublicEDKey) and the daily automatic check are in Info.plist.

#if canImport(Sparkle)
import Sparkle

final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let available = true
    private var controller: SPUStandardUpdaterController?
    /// A found update the user hasn't looked at yet ("1.1.1"); the click menu offers it until they do.
    private(set) var pending: String?
    var onPendingChange: () -> Void = {}

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automatic: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func check() {
        // A menu bar app is never frontmost on its own; Sparkle's window would open behind the current app.
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        controller?.checkForUpdates(nil)
    }

    // Limitbar has no Dock icon, so Sparkle would open a scheduled update's window behind other apps, where it
    // goes unseen. Instead: bring it to the front once, and keep "Update Available…" in the click menu until the
    // user has dealt with it.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        pending = update.displayVersionString
        onPendingChange()
        if handleShowingUpdate {
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pending = nil
        onPendingChange()
    }

    func standardUserDriverWillFinishUpdateSession() {
        pending = nil
        onPendingChange()
    }
}
#else
final class Updates {
    static let available = false
    var automatic = false
    let pending: String? = nil
    var onPendingChange: () -> Void = {}
    func check() {}
}
#endif
