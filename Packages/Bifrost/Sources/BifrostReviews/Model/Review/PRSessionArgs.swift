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
// A parked request session resumes with no start flag (resume): a resume with a flag starts a
// copy of the session with a new session ID. The session restores the flags of its start (its
// saved options) by itself, and claude prints a note that names them (resumeNote). A hands-on
// check found this note with claude 2.1.328.
import BifrostFoundation
import BifrostSessions
import CryptoKit
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

    // The prompt of a conflict round in the request session of the PR: the conflict skill and the
    // path of the input file.
    package static func conflictPrompt(_ inputFile: URL) -> String {
        "/bifrost-resolve-conflicts bifrost-input=\(inputFile.path(percentEncoded: false))"
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

    // claude --bg --resume <session id> <prompt>: the resume of a parked request session.
    package static func resume(_ id: SessionID, prompt: String) -> [String] {
        ["--bg", "--resume", id.text, prompt]
    }

    // The profile of the start arguments of a session: the SHA-256 (hex) of the arguments with no
    // --name <value>, no --resume <value> and no last argument (the prompt), joined by NUL. A
    // resume keeps the flags of the start, so a turn with another profile (for example another
    // model or other settings) needs a new session.
    package static func profile(_ args: [String]) -> String {
        var kept: [String] = []
        var index = 0
        while index < args.count - 1 {
            if args[index] == "--name" || args[index] == "--resume" {
                index += 2
                continue
            }
            kept.append(args[index])
            index += 1
        }
        let digest = SHA256.hash(data: Data(kept.joined(separator: "\0").utf8))
        return digest.map { byte in
            let text = String(byte, radix: 16)
            return byte < 16 ? "0" + text : text
        }.joined()
    }

    // The flags of a request session that keep it in its sandbox. The note of a resume must name
    // each one.
    package static let resumeLimits = [
        "--restricted", "--strict-mcp-config", "--tools", "--permission-mode", "--settings",
        "--add-dir", "--plugin-dir",
    ]

    // Read the note of a resume in the output of claude: "note: woke session <short id> with its
    // saved options (<flag>, <flag>, ...)." The note must name the session and each flag of
    // resumeLimits. With no such note, Bifrost can't tell that the session kept its limits.
    package static func resumeNote(_ output: String, session: ShortID) -> ResumeNote {
        let pattern = /note: woke session ([0-9a-f]{8}) with its saved options \(([^()\n]*)\)/
        var other: ShortID?
        for match in output.matches(of: pattern.matchingSemantics(.unicodeScalar)) {
            guard let woken = ShortID(match.output.1) else { continue }
            guard woken == session else {
                other = other ?? woken
                continue
            }
            let flags = Set(match.output.2.split(separator: ",").map { $0.trimmed() })
            let missing = resumeLimits.filter { !flags.contains($0) }
            return missing.isEmpty ? .kept : .missing(missing)
        }
        return other.map(ResumeNote.otherSession) ?? .noNote
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

// What the note of a resume says about the limits of the woken session (PRSessionArgs.resumeNote).
package enum ResumeNote: Sendable, Equatable {
    // The note names the session and each limit.
    case kept
    // The output has no note.
    case noNote
    // The note names another session.
    case otherSession(ShortID)
    // The note does not name these limits.
    case missing([String])

    // The reason for the log.
    package var message: String {
        switch self {
        case .kept: "The session kept its limits."
        case .noNote: "claude gave no note of the saved options."
        case .otherSession(let id): "The note of the saved options names session \(id.text)."
        case .missing(let flags):
            "The saved options lack \(flags.joined(separator: ", "))."
        }
    }
}
