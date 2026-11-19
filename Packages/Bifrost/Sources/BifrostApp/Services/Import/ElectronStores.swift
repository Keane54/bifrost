import BifrostFoundation
import Foundation

// The stores that the one-time import copies from the Electron app (ElectronImport). The raw
// value is the name of the file. The two apps use the same names and the same fields, each in its
// own support folder. The usage alerts file comes now, so the usage alerts of a later phase can
// read it.
package enum ImportedStore: String, Sendable, CaseIterable {
    case settings = "settings.json", registry = "registry.json", uiState = "ui-state.json"
    case windowState = "window-state.json", usageAlerts = "usage-alerts.json"

    // True for a store whose file has a version field. The import takes only version 1 of it.
    var hasVersion: Bool { self == .settings || self == .uiState }
}

// What the read of the file of a store gives.
package enum ElectronFile: Sendable, Equatable {
    // No item is at the path, or a link at the path points to no item.
    case missing
    // The item at the path is not a regular file: for example a folder or a FIFO.
    case notAFile
    // The bytes of the regular file.
    case data(Data)
}

// The support folder of the Electron app. The type only reads: it never opens a file for writing,
// and it never makes a file or a folder.
package struct ElectronStores: Sendable {
    // The name of the support folder of the Electron app in Application Support.
    private static let folderName = "Bifrost"

    // The folder <home>/Library/Application Support/Bifrost.
    package let folder: URL

    // The support folder of the Electron app in the home.
    package init(home: URL) {
        folder = home.appending(
            path: "Library/Application Support/\(Self.folderName)", directoryHint: .isDirectory)
    }

    // The support folder of the Electron app at this path (StartPlan.electronSupport).
    package init(folder: URL) {
        self.folder = folder
    }

    // Read the file of the store. The open follows a link, and it does not wait (O_NONBLOCK), so
    // a FIFO at the path cannot hold the import. Only a regular file gives its bytes. A read error
    // throws, for example no permission. The caller runs this on the blocking executor.
    package func read(_ store: ImportedStore) throws(FileError) -> ElectronFile {
        let path = folder.appending(path: store.rawValue, directoryHint: .notDirectory)
            .path(percentEncoded: false)
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return .missing }
            throw .system(.read, path: path, code: code)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .system(.check, path: path, code: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notAFile }
        do {
            return .data(try handle.readToEnd() ?? Data())
        } catch {
            throw FileError(error, call: .read, path: path)
        }
    }
}
