import BifrostSessions
import Testing

// An env as Bifrost gets it when a Claude Code Bash tool in Warp runs the development build.
// A key with no value is not in a Swift dictionary, so the env has no key UNSET.
private let source: [String: String] = [
    "ANTHROPIC_MODEL": "haiku",
    "CLAUDE_CODE_CHILD_SESSION": "1",
    "CLAUDE_CODE_ENTRYPOINT": "cli",
    "CLAUDE_CODE_SESSION_KIND": "bash",
    "CLAUDE_CONFIG_DIR": "/Users/test/.claude",
    "CLAUDECODE": "1",
    "HOME": "/Users/test",
    "LANG": "en_GB.UTF-8",
    "PATH": "/usr/bin:/bin",
    "SHELL": "/bin/zsh",
    "TERM": "dumb",
    "TERM_PROGRAM": "WarpTerminal",
    "TERM_PROGRAM_VERSION": "v0.2026",
    "TERM_SESSION_ID": "abc",
    "USER": "test",
    "WARP_HONOR_PS1": "0",
    "WARP_IS_LOCAL_SHELL_SESSION": "1",
]

private let removed = [
    "CLAUDECODE",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_SESSION_KIND",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "TERM_SESSION_ID",
    "WARP_IS_LOCAL_SHELL_SESSION",
    "WARP_HONOR_PS1",
]

@Suite("child environment")
struct ChildEnvironmentTests {
    @Test("the child environment drops the Claude Code, terminal and Warp variables")
    func removes() {
        for pty in [true, false] {
            let env = ChildEnvironment.make(from: source, pty: pty)
            for key in removed { #expect(env[key] == nil, "\(key), pty \(pty)") }
        }
    }

    @Test("the child environment keeps other variables and drops the keys with no value")
    func keeps() {
        let env = ChildEnvironment.make(from: source, pty: false)
        #expect(
            env == [
                "ANTHROPIC_MODEL": "haiku",
                "CLAUDE_CONFIG_DIR": "/Users/test/.claude",
                "HOME": "/Users/test",
                "LANG": "en_GB.UTF-8",
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/zsh",
                "TERM": "dumb",
                "USER": "test",
            ])
    }

    @Test("a PTY child gets TERM and COLORTERM")
    func pty() {
        let env = ChildEnvironment.make(from: source, pty: true)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["HOME"] == "/Users/test")
    }

    // A dictionary is a value, so the function cannot change the source. The check stays.
    @Test("the child environment leaves its source unchanged")
    func sourceStays() {
        let copy = source
        _ = ChildEnvironment.make(from: source, pty: true)
        #expect(source == copy)
    }
}
