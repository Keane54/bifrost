import Foundation

public enum DataFoldersError: Error, Equatable {
    /// A file or other non-folder item sits at this path.
    case notAFolder(String)
}

/// The two data folders of the app. Only the owner can use them.
public struct DataFolders: Sendable, Equatable {
    public let support: URL
    public let dot: URL

    /// The logs folder of the app: `<home>/Library/Logs/<the folder name of the app>`. It is in the
    /// home of the folders, so a test home writes its logs under the test home. Nothing makes it:
    /// the first write of a log makes it.
    package var logs: URL {
        support.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(support.lastPathComponent, isDirectory: true)
    }

    public init(identity: AppIdentity, home: URL) {
        support = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(identity.supportFolderName, isDirectory: true)
        dot = home.appendingPathComponent(identity.dotFolderName, isDirectory: true)
    }

    /// Makes the missing folders with mode 0700. Existing folders stay as they are.
    public func create() throws {
        for folder in [support, dot] {
            try create(folder)
        }
    }

    private func create(_ folder: URL) throws {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        if manager.fileExists(atPath: folder.path, isDirectory: &isFolder) {
            guard isFolder.boolValue else { throw DataFoldersError.notAFolder(folder.path) }
            return
        }
        try manager.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
