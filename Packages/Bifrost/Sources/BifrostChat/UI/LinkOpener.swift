// The links of a chat window (docs/behaviour/chat.md, "Links"). A Cmd+click on a link opens it
// outside the app, with no dialog (user decisions, 2026-11-10 and 2026-11-14). The rules are
// LinkRules of the chat model: the action comes from the real path of a file, a file that runs when
// macOS opens it shows in Finder and does not run, and a file opens only in the app that the rules
// checked.
import AppKit
import Darwin
import UniformTypeIdentifiers

// Runs the action of a link. The app uses system. A test gives fake apps, a manual clock and a
// fake open that only records the action, so a test never asks Launch Services, opens a link or
// starts an app.
@MainActor
public final class LinkOpener {
    // The lookups of Launch Services for the link rules: one at a time for all links.
    let lookup: OpenerLookup
    // The clock of the time limit of Launch Services.
    let clock: any Clock<Duration>
    let open: (LinkAction) async -> Void
    // The number of the last click. Only the action of the last click runs.
    private var lastClick = 0

    // The number of Cmd+clicks. A test checks that a plain click made none.
    package var clicks: Int { lastClick }

    package init(
        apps: any DefaultApps, clock: any Clock<Duration> = ContinuousClock(),
        open: @escaping (LinkAction) async -> Void
    ) {
        lookup = OpenerLookup(apps: apps)
        self.clock = clock
        self.open = open
    }

    // The default browser, the checked app of a file, or Finder.
    public static let system = LinkOpener(apps: SystemDefaultApps()) { await perform($0) }

    // A Cmd+click on a link. The rules read the file system and ask Launch Services off the main
    // actor. When the user clicks a newer link before the action of this link is ready, this
    // link does nothing. The task ends after the open (a test waits for it).
    @discardableResult
    package func click(_ link: String) -> Task<Void, Never> {
        lastClick += 1
        let click = lastClick
        let lookup = lookup
        let clock = clock
        return Task {
            let action = await LinkRules.action(
                forLink: link, localHost: Self.hostName(), lookup: lookup, clock: clock)
            guard click == lastClick else { return }
            await open(action)
        }
    }

    // The effect of an action. The opens are async, so the main actor does not wait for Launch
    // Services. A file opens in the app that the rules checked. A file with no app opens with no
    // app: then macOS asks the user for an app.
    private static func perform(_ action: LinkAction) async {
        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()
        switch action {
        case .openWeb(let url):
            _ = try? await workspace.open(url, configuration: configuration)
        case .openFile(let path, let app?):
            _ = try? await workspace.open(
                [URL(filePath: path)], withApplicationAt: app, configuration: configuration)
        case .openFile(let path, nil):
            _ = try? await workspace.open(URL(filePath: path), configuration: configuration)
        case .showInFinder(let path):
            workspace.activateFileViewerSelecting([URL(filePath: path)])
        case .nothing:
            break
        }
    }

    // The host name of this Mac (gethostname(3)). ProcessInfo.hostName can wait for the network,
    // so it is not used.
    nonisolated static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        let name = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: name, as: UTF8.self)
    }
}

// The apps of Launch Services (NSWorkspace). The terminals are the apps that declare
// public.unix-executable. Launch Services keeps the choice of a default app by bundle ID, so the
// rules use bundle IDs. A terminal with no bundle ID is not in the set, but as the app of a file
// it has no bundle ID, so the file shows in Finder.
nonisolated struct SystemDefaultApps: DefaultApps {
    func opener(of file: FileFacts) -> OpenerFacts {
        let workspace = NSWorkspace.shared
        let item = URL(
            filePath: file.realPath, directoryHint: file.isFolder ? .isDirectory : .notDirectory)
        let app = workspace.urlForApplication(toOpen: item)
        let terminals = workspace.urlsForApplications(toOpen: .unixExecutable)
        return OpenerFacts(
            app: app.map { AppFacts(url: $0, bundleID: Self.bundleID(of: $0)) },
            typeApp: workspace.urlForApplication(toOpen: file.contentType),
            terminalIDs: Set(terminals.compactMap(Self.bundleID(of:))))
    }

    private static func bundleID(of app: URL) -> String? { Bundle(url: app)?.bundleIdentifier }
}
