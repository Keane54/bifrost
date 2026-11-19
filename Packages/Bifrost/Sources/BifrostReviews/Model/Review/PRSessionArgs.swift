// The arguments of "claude --bg" for the PR sessions (docs/behaviour/reviews.md, "PR sessions").
// Claude Code enforces the limits of each kind, so a PR body or a comment cannot make Claude post,
// push or send data out:
// - A review session is read-only: --restricted, no MCP server, only the tools Read, Glob, Grep,
//   Write and Skill, and the mode auto. It has no shell, no web tool and no tool that sends data
//   out, so it cannot run PR code, gh, git or curl. Its file tools stay in the worktree and the
//   input folder.
// - A request session has Bash in the Claude Code sandbox and the Edit tool, and also runs with
//   --restricted: its file tools stay in the worktree and the input folder, so they can't read the
//   folders of another PR. --restricted loads no settings file of the user or of the PR head (no
//   hooks, MCP servers or CLAUDE.md of the PR head), so the settings value holds all the rules
//   (RequestSandbox). Under --restricted a write to a settings, git or tool configuration file
//   asks a person first; a session of a round never gets an answer, so the round stops as
//   blocked.
// The model comes before the name when the setting names one. The prompt is last, and no flag
// with many values comes just before it. Each value is one argument: no shell reads them.
import BifrostSessions
import Foundation

package enum PRSessionArgs {
    // The tools of a review session: read, search, and write its result file.
    package static let reviewTools = ["Read", "Glob", "Grep", "Write", "Skill"]
    // The tools of a request session: also Bash in the sandbox and Edit.
    package static let requestTools = ["Bash", "Read", "Glob", "Grep", "Edit", "Write", "Skill"]

    // The --settings value of a review session: no statusline, and no hook at all. A PR head can
    // hold a .claude folder with hooks, so the session runs no hook (defence in depth). One
    // argument, and no shell reads it.
    package static let reviewSettings =
        #"{"statusLine":{"type":"command","command":"true"},"disableAllHooks":true}"#

    // The prompt of a review session: the skill and the path of the input file. The path can
    // hold spaces: the skill reads the rest of the text as the path.
    package static func reviewPrompt(_ inputFile: URL) -> String {
        "/bifrost-review bifrost-input=\(inputFile.path(percentEncoded: false))"
    }

    // The prompt of a request session: the skill and the path of the input file.
    package static func requestPrompt(_ inputFile: URL) -> String {
        "/bifrost-resolve-comments bifrost-input=\(inputFile.path(percentEncoded: false))"
    }

    // claude --bg --restricted --strict-mcp-config --tools Read Glob Grep Write Skill
    // --permission-mode auto --add-dir <input folder> --plugin-dir <skills> --settings <value>
    // [--model <model>] --name <name> <prompt>
    package static func review(
        name: String, model: ModelChoice, inputFolder: URL, skills: URL, prompt: String
    ) -> [String] {
        ["--bg", "--restricted", "--strict-mcp-config", "--tools"] + reviewTools
            + common(inputFolder: inputFolder, skills: skills, settings: reviewSettings)
            + tail(name: name, model: model, prompt: prompt)
    }

    // claude --bg --restricted --strict-mcp-config --tools Bash Read Glob Grep Edit Write Skill
    // --permission-mode auto --add-dir <input folder> --plugin-dir <skills> --settings <settings>
    // [--model <model>] --name <name> <prompt>
    package static func request(
        name: String, model: ModelChoice, inputFolder: URL, skills: URL, settings: String,
        prompt: String
    ) -> [String] {
        ["--bg", "--restricted", "--strict-mcp-config", "--tools"] + requestTools
            + common(inputFolder: inputFolder, skills: skills, settings: settings)
            + tail(name: name, model: model, prompt: prompt)
    }

    // The flags after the tools: the mode, the input folder, the skills and the settings.
    private static func common(inputFolder: URL, skills: URL, settings: String) -> [String] {
        [
            "--permission-mode", "auto", "--add-dir", inputFolder.plainPath, "--plugin-dir",
            skills.plainPath, "--settings", settings,
        ]
    }

    // The model (when the setting names one), the name and the prompt.
    private static func tail(name: String, model: ModelChoice, prompt: String) -> [String] {
        let model = model == .standard ? [] : ["--model", model.rawValue]
        return model + ["--name", name, prompt]
    }
}
