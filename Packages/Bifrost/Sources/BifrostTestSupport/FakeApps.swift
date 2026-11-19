import BifrostSessions
import Foundation

// An opener that records each open, activate, reveal and open in the browser, and opens nothing,
// so no test opens or activates an app or a browser. With failure set, each open, activate and
// open in the browser throws it after the record. The packages are the paths that count as
// packages, and kinds gives the kind of other paths. Each other path is a folder. The kind check
// gives the URL as it came: the fake resolves no link.
@MainActor
package final class FakeOpener: AppOpener {
    package enum Call: Equatable, Sendable {
        case open(file: String, app: String)
        case activate(app: String)
        case reveal(String)
        // The absolute text of the address.
        case browse(String)
    }

    // The kind of a path that is not a plain folder or a package. link is a link to the folder
    // at its path.
    package enum Kind: Sendable {
        case other, missing, unreadable, unknown
        case link(String)
    }

    package private(set) var calls: [Call] = []
    package var failure: ActionRefusal?
    package var packages: Set<String>
    package var kinds: [String: Kind]

    package init(
        failure: ActionRefusal? = nil, packages: Set<String> = [], kinds: [String: Kind] = [:]
    ) {
        self.failure = failure
        self.packages = packages
        self.kinds = kinds
    }

    package func kind(_ url: URL) async -> PathKind {
        let path = Self.path(url)
        if packages.contains(path) { return .package(url) }
        switch kinds[path] {
        case .other: return .other
        case .missing: return .missing
        case .unreadable: return .unreadable
        case .unknown: return .unknown
        case .link(let target): return .folder(URL(filePath: target, directoryHint: .isDirectory))
        case nil: return .folder(url)
        }
    }

    package func reveal(_ url: URL) {
        calls.append(.reveal(Self.path(url)))
    }

    package func open(_ file: URL, with app: URL) async throws(ActionRefusal) {
        calls.append(.open(file: Self.path(file), app: Self.path(app)))
        if let failure { throw failure }
    }

    package func activate(_ app: URL) async throws(ActionRefusal) {
        calls.append(.activate(app: Self.path(app)))
        if let failure { throw failure }
    }

    // As the real opener, an address that is not https throws and is not recorded.
    package func openInBrowser(_ url: URL) async throws(ActionRefusal) {
        guard url.scheme?.lowercased() == "https" else { throw .openFailed(AppActions.httpsOnly) }
        calls.append(.browse(url.absoluteString))
        if let failure { throw failure }
    }

    // The path of the URL with no "/" at the end, as a test writes it.
    private static func path(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

// A clipboard that records each text.
@MainActor
package final class FakeClipboard: Clipboard {
    package private(set) var texts: [String] = []

    package init() {}

    package func write(_ text: String) { texts.append(text) }
}
