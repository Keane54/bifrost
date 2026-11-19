import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import BifrostLive
@testable import BifrostSettings

// The parts of the tests of Settings > Live details and Settings > Skills: the real Live details
// control and the real skills control in a test home in a short temporary folder, each with a
// runner of its plugin commands that runs no program. The shared paths are the paths of the test
// home, so the mod goes to <test home>/.bifrost/mod and the server listens on
// <test home>/.bifrost/live.sock. No test runs claude or touches the real home.

// A runner of the plugin commands of one plugin of Bifrost that runs no program. It keeps a
// small plugin state: the plugin, on or off, and the marketplace of Bifrost after an add. Each
// list command adds one to its count. A write of the verb in failing fails with the stderr
// "boom". While hold is set, each write waits at the gate first. After holdLists(n), the next n
// plugin lists read the state, then wait at the list gate, so each one gives the state from
// before the wait.
final class FakePlugins: CommandRunner {
    struct State {
        var installed: Bool
        var enabled: Bool
        var listFails = false
        var failing: String?
        var marketplace: String?
        var lists = 0
        var writes: [String] = []
        var listHolds = 0
    }

    let ids: PluginIDs
    let gate = TestGate()
    let listGate = TestGate()
    private let state: Mutex<State>
    private let holding = Mutex(false)

    init(_ ids: PluginIDs, installed: Bool = false, enabled: Bool = false) {
        self.ids = ids
        state = Mutex(State(installed: installed, enabled: enabled))
    }

    var lists: Int { state.withLock { $0.lists } }
    var writes: [String] { state.withLock { $0.writes } }

    func change(_ edit: (inout State) -> Void) {
        state.withLock { edit(&$0) }
    }

    func holdLists(_ count: Int) {
        state.withLock { $0.listHolds = count }
    }

    func hold(_ on: Bool) {
        holding.withLock { $0 = on }
        if !on { gate.openAll() }
    }

    func run(_ command: Command) async -> ExecResult {
        let arguments = command.arguments
        switch arguments {
        case ["plugin", "list", "--json"]:
            let (fails, list, held) = state.withLock { s in
                s.lists += 1
                let entry = #"[{"id":"\#(ids.plugin)","enabled":\#(s.enabled)}]"#
                let held = s.listHolds > 0
                if held { s.listHolds -= 1 }
                return (s.listFails, s.installed ? entry : "[]", held)
            }
            if held { await listGate.pass() }
            if fails { return ExecResult(.exited(1), stderr: "the list failed") }
            return ExecResult(.exited(0), stdout: list)
        case ["plugin", "marketplace", "list", "--json"]:
            let path = state.withLock { $0.marketplace }
            let list = path.map {
                #"[{"name":"\#(ids.marketplace)","source":"directory","path":"\#($0)"}]"#
            }
            return ExecResult(.exited(0), stdout: list ?? "[]")
        default:
            if holding.withLock({ $0 }) { await gate.pass() }
            return write(Array(arguments.dropFirst().dropLast(3)))
        }
    }

    // A write: the verb words and the value, with no "plugin" before and no scope after.
    private func write(_ words: [String]) -> ExecResult {
        state.withLock { s in
            s.writes.append(words.joined(separator: " "))
            let verb = words.dropLast().joined(separator: " ")
            if verb == s.failing { return ExecResult(.exited(1), stderr: "boom") }
            switch verb {
            case "install":
                s.installed = true
                s.enabled = true
            case "enable": s.enabled = true
            case "disable": s.enabled = false
            case "uninstall":
                s.installed = false
                s.enabled = false
            case "marketplace add": s.marketplace = words.last
            case "marketplace remove": s.marketplace = nil
            default: break
            }
            return ExecResult(.exited(0), stdout: #"{"outcome":"ok"}"#)
        }
    }
}

// The two controls in a test home and the live model on them. A test gives the model to the
// Settings parts (SettingsParts(live:)).
@MainActor
final class LiveParts {
    let folder: TemporaryFolder
    let paths: SharedClaudeState
    let lock = SerialLock()
    let livePlugins: FakePlugins
    let skillsPlugins: FakePlugins
    let liveControl: LiveControl
    let skillsControl: SkillsControl
    // The clock of the back-off of the model. The plugin commands and the server have their own
    // clock, which no test moves.
    let clock = ManualClock()
    let model: LiveModel
    // The version check of Bifrost that the model gets, and the number of its runs.
    var version = ClaudeVersionCheck(
        version: "2.1.300", ok: true, minimum: ClaudeVersionCheck.appMinimum)
    private(set) var versionChecks = 0
    // The version that the Live details control gets.
    var liveVersion: ClaudeCodeVersion = "2.1.300"

    init(live: FakePlugins? = nil, skills: FakePlugins? = nil) throws {
        try TestSandbox.require()
        folder = try TemporaryFolder(short: true)
        paths = SharedClaudeState(home: URL(fileURLWithPath: folder.path, isDirectory: true))
        livePlugins = live ?? FakePlugins(.live)
        skillsPlugins = skills ?? FakePlugins(.skills)
        let commandClock = ManualClock()
        let liveRunner = ClaudeRunner(
            path: FakeRunner.claudePath, baseEnvironment: [:], runner: livePlugins)
        let skillsRunner = ClaudeRunner(
            path: FakeRunner.claudePath, baseEnvironment: [:], runner: skillsPlugins)
        let resources = try Repo.root().appending(path: "App/Bifrost/Resources")
        let checks = VersionBox()
        liveControl = LiveControl(
            paths: paths,
            cli: { PluginCLI(claude: liveRunner, ids: .live, clock: commandClock) },
            version: { checks.live() },
            server: { socket in
                LiveServer(
                    socketPath: socket.path(percentEncoded: false), clock: commandClock,
                    batchWindow: .zero, onEvents: { _ in })
            },
            registry: nil, modSource: resources.appending(path: "live-mod"), lock: lock,
            forceListen: false, log: SystemLiveLog())
        skillsControl = SkillsControl(
            paths: paths,
            cli: { PluginCLI(claude: skillsRunner, ids: .skills, clock: commandClock) },
            source: resources.appending(path: "bifrost-skills"), lock: lock, log: SystemLiveLog())
        model = LiveModel(clock: clock)
        checks.parts = self
    }

    var sources: LiveModel.Sources {
        LiveModel.Sources(live: liveControl, skills: skillsControl) { [weak self] in
            guard let self else {
                return ClaudeVersionCheck(version: nil, ok: false, minimum: "2.1.281")
            }
            versionChecks += 1
            return version
        }
    }

    // Give the controls to the model, and wait for its first reads.
    func attach() async {
        model.attach(sources)
        await model.firstReads?.value
    }

    func finish() {
        model.stop()
        liveControl.stop()
        skillsControl.stop()
        folder.remove()
    }

    // The version that the Live details control gets, from liveVersion.
    fileprivate func liveCheck() -> ClaudeVersionCheck {
        ClaudeVersionCheck(
            version: liveVersion, ok: liveVersion >= ClaudeVersionCheck.liveMinimum,
            minimum: ClaudeVersionCheck.liveMinimum)
    }

    // The mod folder with no "/" at its end, as Bifrost gives it to claude.
    var modFolder: String { folder.appending(".bifrost/mod") }
}

// The link from the version closure of the Live details control to the parts, which exist only
// after the control.
@MainActor
private final class VersionBox: Sendable {
    weak var parts: LiveParts?

    func live() -> ClaudeVersionCheck {
        parts?.liveCheck()
            ?? ClaudeVersionCheck(version: nil, ok: false, minimum: ClaudeVersionCheck.liveMinimum)
    }
}

// The bodies of a side bar with no panel body.
final class NoBodies: PanelBodies {
    func body(for panel: PanelID) -> NSView { NSView() }
    func title(for panel: PanelID) -> String { "" }
    func titleSuffix(for panel: PanelID) -> String? { nil }
    func releaseBody(for panel: PanelID) {}
}

// The height that a view takes at a width of 720 points, after SwiftUI drew it.
@MainActor
func fittingHeight(_ view: some View) -> CGFloat {
    UITestApp.prepare()
    let host = NSHostingView(rootView: view.frame(width: 720))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}
