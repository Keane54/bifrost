import Foundation

// The git program that the tests run. /usr/bin/git is only a stub that asks xcrun for the git of
// the active developer folder on every start, which adds around 50 ms to each run in the test
// sandbox, and a round test of Reviews runs dozens of git commands. So we ask xcrun once per test
// process and run that git directly, which is the same program the stub would start. If xcrun
// can't name one, the tests fall back to the stub.
package let testGit: String = {
    let stub = "/usr/bin/git"
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = ["--find", "git"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return stub
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, path.hasPrefix("/"),
        FileManager.default.isExecutableFile(atPath: path)
    else { return stub }
    return path
}()
