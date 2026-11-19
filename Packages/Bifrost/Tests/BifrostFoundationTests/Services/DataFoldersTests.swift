import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation

private func mode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? Int) ?? -1
}

private func developmentIdentity() throws -> AppIdentity {
    try #require(AppIdentity(bundleID: "com.example.app.native-dev"))
}

@Test func developmentFoldersAreNotElectronFolders() throws {
    let home = URL(fileURLWithPath: "/tmp/x")
    let folders = DataFolders(identity: try developmentIdentity(), home: home)
    #expect(folders.support.path
        == "/tmp/x/Library/Application Support/Bifrost Native Dev")
    #expect(folders.dot.path == "/tmp/x/.bifrost-native-dev")
    #expect(folders.support.lastPathComponent != "Bifrost")
    #expect(folders.dot.lastPathComponent != ".bifrost")
}

@Test func createMakesBothFoldersWithMode0700() throws {
    let temp = try TemporaryFolder()
    defer { temp.remove() }
    let home = temp.url
    let folders = DataFolders(identity: try developmentIdentity(), home: home)
    try folders.create()
    #expect(try mode(of: folders.support) == 0o700)
    #expect(try mode(of: folders.dot) == 0o700)
}

@Test func createIsIdempotent() throws {
    let temp = try TemporaryFolder()
    defer { temp.remove() }
    let home = temp.url
    let folders = DataFolders(identity: try developmentIdentity(), home: home)
    try folders.create()
    try folders.create()
    #expect(try mode(of: folders.dot) == 0o700)
}

@Test func createRefusesAFileAtTheFolderPath() throws {
    let temp = try TemporaryFolder()
    defer { temp.remove() }
    let home = temp.url
    let folders = DataFolders(identity: try developmentIdentity(), home: home)
    #expect(FileManager.default.createFile(atPath: folders.dot.path, contents: Data()))
    #expect(throws: DataFoldersError.notAFolder(folders.dot.path)) {
        try folders.create()
    }
}

@Test func createKeepsTheModeOfAnExistingFolder() throws {
    let temp = try TemporaryFolder()
    defer { temp.remove() }
    let home = temp.url
    let folders = DataFolders(identity: try developmentIdentity(), home: home)
    try FileManager.default.createDirectory(
        at: folders.dot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
    )
    try folders.create()
    #expect(try mode(of: folders.dot) == 0o755)
}

@Test func theLogsFolderIsInTheLibraryOfTheHome() throws {
    let home = URL(fileURLWithPath: "/tmp/x")
    let development = DataFolders(identity: try developmentIdentity(), home: home)
    #expect(development.logs.path == "/tmp/x/Library/Logs/Bifrost Native Dev")
    let release = try #require(AppIdentity(bundleID: "com.example.app"))
    #expect(DataFolders(identity: release, home: home).logs.path == "/tmp/x/Library/Logs/Bifrost")
}
