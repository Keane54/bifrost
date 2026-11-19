import BifrostApp
import BifrostFoundation
import BifrostSettings
import Foundation
import Sparkle

/// Holds the Sparkle updater of the app.
/// The updater starts only when `UpdatePolicy` allows it: in the release app with a feed URL and
/// a public key in the Info.plist. In all other builds, the updater stays stopped.
@MainActor
final class Updates {
    private let controller: SPUStandardUpdaterController
    private let started: Bool
    /// What the updater does now and when it last checked. Settings > Updates reads it. The
    /// delegate of Sparkle changes it at the events of the updater: a check starts, and an update
    /// cycle ends.
    let state = UpdaterState()
    /// Gets the result of each update cycle: true when the cycle ended with no error or found no
    /// update (UpdatePolicy.cycleSucceeded). The app delegate sets it when the shell exists, and
    /// the shell gives the result to the health log.
    var cycleResult: (@MainActor (Bool) -> Void)?
    /// Runs when the automatic checks turn off. The app delegate sets it when the shell exists,
    /// and the shell ends the streak of failed checks in the health log.
    var checksStopped: (@MainActor () -> Void)?
    private let delegate: Delegate

    init(variant: AppVariant) {
        let started = UpdatePolicy.startsUpdater(
            variant: variant,
            feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
        let delegate = Delegate()
        controller = SPUStandardUpdaterController(
            startingUpdater: started,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        self.started = started
        self.delegate = delegate
        state.phase = started ? .idle : .off
        state.lastCheck = started ? controller.updater.lastUpdateCheckDate : nil
        delegate.onStart = { [weak self] in self?.state.phase = .checking }
        delegate.onCycleEnd = { [weak self] in self?.cycleEnded($0) }
    }

    /// The version of the app (CFBundleShortVersionString), or nil.
    var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The end of an update cycle: the updater is idle again and has a new time of the last check.
    /// Without a start event, the phase never leaves idle, so "checking" never sticks. The result
    /// of the cycle goes to cycleResult.
    private func cycleEnded(_ error: (any Error)?) {
        guard started else { return }
        state.phase = .idle
        state.lastCheck = controller.updater.lastUpdateCheckDate
        let failure = error.map { error -> (domain: String, code: Int) in
            let error = error as NSError
            return (error.domain, error.code)
        }
        cycleResult?(UpdatePolicy.cycleSucceeded(failure))
    }

    /// True when the updater runs and can start a check now.
    var canCheck: Bool {
        started && controller.updater.canCheckForUpdates
    }

    /// Starts a check for updates and shows the result. Does nothing when `canCheck` is false.
    func checkForUpdates() {
        guard canCheck else { return }
        controller.checkForUpdates(nil)
    }

    /// Turns the automatic checks and downloads on or off (Check for updates automatically). Off
    /// stops the scheduled checks, and checksStopped runs. A check from the menu still works.
    /// Does nothing while the updater is stopped, as in a development build.
    func setAutomatic(_ on: Bool) {
        guard started else { return }
        controller.updater.automaticallyChecksForUpdates = on
        controller.updater.automaticallyDownloadsUpdates = on
        if !on { checksStopped?() }
    }

    /// The delegate of the updater. Sparkle calls mayPerformUpdateCheck before each check, the
    /// scheduled ones and the ones of the user, and didFinishUpdateCycleFor when the update driver
    /// ends, with or without an error. The window of Sparkle can stay open between the two.
    private final class Delegate: NSObject, SPUUpdaterDelegate {
        var onStart: (@MainActor () -> Void)?
        var onCycleEnd: (@MainActor ((any Error)?) -> Void)?

        func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
            onStart?()
        }

        func updater(
            _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
            error: (any Error)?
        ) {
            onCycleEnd?(error)
        }
    }
}
