import BifrostSessions
import Testing

// The parse of the environment of the login shell (docs/behaviour/process.md). The app reads the
// output of "/usr/bin/env -0":
// each entry is KEY=VALUE and ends with a NUL. The texts below are recorded output, with the
// command that made each one.

private let marker = LoginEnvironmentText.marker

// env -i PATH=/a HOME=/h /usr/bin/env -0
private let pathAndHome = "PATH=/a\u{0}HOME=/h\u{0}"

// env -i PATH=/a 'X=a=b' "NL=one<line feed>two" /usr/bin/env -0
private let equalsAndLineFeed = "PATH=/a\u{0}X=a=b\u{0}NL=one\ntwo\u{0}"

// env -i HOME=/h /usr/bin/env -0
private let homeOnly = "HOME=/h\u{0}"

@Suite("login environment output")
struct LoginEnvironmentTextTests {
    @Test("only the text between the markers is read")
    func betweenMarkers() {
        let out = "banner text\n\(marker)\(pathAndHome)\(marker)\nmore"
        #expect(LoginEnvironmentText.parse(out) == ["HOME": "/h", "PATH": "/a"])
    }

    // An entry with no "=" is the Swift form of bad JSON.
    @Test
    func noMarkersOrBadEntry() {
        #expect(LoginEnvironmentText.parse(pathAndHome) == nil)
        #expect(LoginEnvironmentText.parse("\(marker)PATH=/a\u{0}bad\u{0}\(marker)") == nil)
    }

    // The output of env -0 holds only text, so a value is always a string. An empty key is the
    // Swift form of a value that is not a string. {} and {"HOME":"/h"} stay. The message of a
    // failure gives the text with its NUL as "\0": a NUL cuts an XUnit report.
    @Test
    func noPathOrEmptyKey() {
        for text in ["=x\u{0}PATH=/a\u{0}", "", homeOnly] {
            #expect(
                LoginEnvironmentText.parse("\(marker)\(text)\(marker)") == nil,
                "\(text.debugDescription)")
        }
    }

    // A value keeps each "=" after the first one and its line feeds. The NUL at the end
    // of the output gives no entry.
    @Test func aValueKeepsItsEqualsSignsAndLineFeeds() {
        let env = LoginEnvironmentText.parse("\(marker)\(equalsAndLineFeed)\(marker)")
        #expect(env == ["NL": "one\ntwo", "PATH": "/a", "X": "a=b"])
    }

    // The script prints the path of claude between two claude markers, then the env with NUL
    // ends between two env markers.
    @Test func theScriptPrintsThePathAndTheEnvBetweenTheirMarkers() {
        #expect(
            LoginEnvironmentText.script
                == "printf '%s' '__BIFROST_CLAUDE__'; command -v claude; "
                + "printf '%s' '__BIFROST_CLAUDE__'; "
                + "printf '%s' '__BIFROST_ENV__'; /usr/bin/env -0; printf '%s' '__BIFROST_ENV__'")
        #expect(marker == "__BIFROST_ENV__")
        #expect(LoginEnvironmentText.claudeMarker == "__BIFROST_CLAUDE__")
    }

    // The path of claude is the last line between the claude markers, when it is absolute.
    @Test func thePathOfClaudeIsTheLastLineBetweenItsMarkers() {
        let mark = LoginEnvironmentText.claudeMarker
        let path = { (text: String) in LoginEnvironmentText.claudePath(text) }
        #expect(path("banner\n\(mark)/opt/bin/claude\n\(mark)") == "/opt/bin/claude")
        #expect(path("\(mark)note\n  /a/claude  \n\(mark)x") == "/a/claude")
        #expect(path("\(mark)claude: aliased\n\(mark)") == nil)
        #expect(path("\(mark)\(mark)") == nil)
        #expect(path("/a/claude") == nil)
        #expect(path("\(mark)/a/claude") == nil)
    }
}
