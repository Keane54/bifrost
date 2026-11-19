import Testing

// The tags of the slow or heavy tests, so a test plan or a script can select the fast pure
// tests: swift test --skip-tag (or a filter in Xcode).
extension Tag {
    // The test starts a real process: a shell, a PTY child, the fake claude or a stand-in.
    @Tag package static var realProcess: Self
    // The test makes a window or a view of AppKit.
    @Tag package static var window: Self
    // The test runs a timer on the real clock.
    @Tag package static var timing: Self
}
