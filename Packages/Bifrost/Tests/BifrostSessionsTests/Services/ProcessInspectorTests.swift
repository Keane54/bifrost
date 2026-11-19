// The command of a process is argv[0],
// as `ps -o comm=` gives it. The data of KERN_PROCARGS2 is argc (an Int32), the path of the
// executable, NUL bytes, then the arguments and the environment, each with a NUL at its end.
// The tests give the data of the parse. The real read is in
// PTYProcessTests.theSystemInspectorReadsAChildThatTheTestStarted.
import Testing

@testable import BifrostSessions

// The data of KERN_PROCARGS2: argc, then the text bytes.
private func arguments(argc: Int32, _ text: String) -> ArraySlice<UInt8> {
    ArraySlice(withUnsafeBytes(of: argc.littleEndian, Array.init) + Array(text.utf8))
}

@Suite("process inspector", .timeLimit(.minutes(1)))
struct ProcessInspectorTests {
    // argv[0] is not the path of the executable: a login shell, a link, a relative path and an
    // argument with a space.
    @Test func theCommandIsArgvZeroAsPsGivesIt() {
        let cases: [(data: ArraySlice<UInt8>, command: String)] = [
            (arguments(argc: 2, "/bin/zsh\0\0\0\0-zsh\0-l\0HOME=/x\0"), "-zsh"),
            (arguments(argc: 1, "/private/tmp/A.app/Contents/MacOS/a\0/tmp/link\0"), "/tmp/link"),
            (arguments(argc: 2, "/bin/sleep\0\0./sleep\0" + "30\0"), "./sleep"),
            (arguments(argc: 1, "/bin/sleep\0with space\0"), "with space"),
        ]
        for item in cases {
            #expect(SystemProcessInspector.firstArgument(inArguments: item.data) == item.command)
        }
    }

    // ps skips each NUL byte after the path of the executable, so an empty argv[0] gives the
    // next argument.
    @Test func anEmptyArgvZeroGivesTheNextArgumentAsInPs() {
        let data = arguments(argc: 2, "/bin/sleep\0\0\0\0" + "30\0")
        #expect(SystemProcessInspector.firstArgument(inArguments: data) == "30")
    }

    // Data with no complete first argument gives nil, so the read uses the path of the
    // executable: no argument, a first argument with no NUL at its end, no NUL after the path,
    // and data that is shorter than argc.
    @Test func dataWithNoCompleteFirstArgumentGivesNil() {
        let bad: [ArraySlice<UInt8>] = [
            arguments(argc: 0, "/bin/sleep\0\0\0\0HOME=/x\0"),
            arguments(argc: 1, "/bin/sleep\0\0sleep"),
            arguments(argc: 1, "/bin/sleep"),
            arguments(argc: 1, "/bin/sleep\0\0\0\0"),
            ArraySlice([1, 0, 0]),
            [],
        ]
        for data in bad {
            #expect(SystemProcessInspector.firstArgument(inArguments: data) == nil)
        }
    }

    // The scan of the attach clients reads each argument of a short command line, in order. A
    // command line of more arguments than the limit, and an argument with no NUL at its end,
    // give nil.
    @Test func theArgumentsAreArgvInOrderUpToTheLimit() {
        let attach = arguments(
            argc: 3, "/Users/x/.local/share/claude/versions/2.1.327\0\0\0"
                + "/Users/x/.local/bin/claude\0attach\0b72dc96f\0HOME=/x\0")
        #expect(
            SystemProcessInspector.arguments(inArguments: attach, limit: 8)
                == ["/Users/x/.local/bin/claude", "attach", "b72dc96f"])
        #expect(SystemProcessInspector.arguments(inArguments: attach, limit: 2) == nil)
        let cut = arguments(argc: 3, "/bin/claude\0\0claude\0attach\0b72d")
        #expect(SystemProcessInspector.arguments(inArguments: cut, limit: 8) == nil)
        let none = arguments(argc: 0, "/x\0")
        #expect(SystemProcessInspector.arguments(inArguments: none, limit: 8) == nil)
    }
}
