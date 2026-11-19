import Testing

@testable import BifrostFoundation

@Suite("the real path")
struct RealPathTests {
    // /tmp is a link to /private/tmp on macOS. A "." and a ".." go.
    @Test func aLinkADotAndADotDotResolve() {
        #expect(RealPath.of("/tmp") == "/private/tmp")
        #expect(RealPath.of("/private/./tmp/..") == "/private")
    }

    // A path with a NUL would name another path in C, so it has no real path.
    @Test(arguments: ["", "/nowhere/\u{0}", "/tmp\u{0}x", "/no-such-folder-of-bifrost"])
    func aPathWithNoFileHasNoRealPath(path: String) {
        #expect(RealPath.of(path) == nil)
    }
}
