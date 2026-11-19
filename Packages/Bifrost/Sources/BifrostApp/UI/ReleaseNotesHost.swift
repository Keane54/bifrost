import BifrostFoundation
import BifrostSettings
import BifrostWindows
import Foundation
import Observation

// The release notes dialog in the window (docs/behaviour/updates.md, "Release notes" and "What's
// new"): the open from Settings > Updates, and What's new at the start. The shell holds one.
@MainActor
package final class ReleaseNotesHost {
    // nil when the app has no address of the releases: then nothing opens.
    private let service: ReleaseNotesService?
    // The wait of What's new at the start. It ends when the dialog opens, or at once when the rule
    // gives nothing. A test waits for it.
    private(set) var whatsNew: Task<Void, Never>?

    init(service: ReleaseNotesService?) {
        self.service = service
    }

    isolated deinit {
        whatsNew?.cancel()
    }

    // Open the release notes dialog with the last releases. Nothing opens when the app has no
    // release notes, or while another dialog shows: the result is false then.
    @discardableResult
    func open(in dialogs: DialogHost) -> Bool {
        guard let service else { return false }
        return dialogs.releaseNotes(.all, source: service.source)
    }

    // What's new at the start: the rule decides, with the setup state of now, and stores the
    // version first. Then the dialog opens when the setup is done and no other dialog shows, so it
    // never covers the Setup dialog. Only the release app decides (StartPlan.opensWhatsNew); the
    // others give nothing here. The first call counts.
    func startWhatsNew(version: String?, settings: SettingsStore, dialogs: DialogHost) {
        guard whatsNew == nil, let version, let service else { return }
        whatsNew = Task {
            let setupDone = settings.settings.setupDone
            guard let range = await service.whatsNew(current: version, setupDone: setupDone)
            else { return }
            let ready = Observations { settings.settings.setupDone && !dialogs.isOpen }
            for await isReady in ready where isReady {
                if dialogs.releaseNotes(.whatsNew(range), source: service.source) { return }
            }
        }
    }

    #if DEBUG
    // The test port state of the dialog: null while it does not show, else its view, its load
    // state and the versions that it shows.
    func testPortState(of dialogs: DialogHost) -> JSONValue {
        guard case .releaseNotes(let model) = dialogs.dialog else { return .null }
        let view: String
        switch model.view {
        case .whatsNew: view = "whats-new"
        case .all: view = "all"
        }
        let load: String
        switch model.load {
        case .loading: load = "loading"
        case .failed: load = "failed"
        case .loaded: load = model.isEmpty ? "empty" : "loaded"
        }
        return [
            "view": .string(view), "load": .string(load), "title": .string(model.title),
            "versions": .array(model.shown.map { .string($0.version.description) }),
        ]
    }
    #endif
}
