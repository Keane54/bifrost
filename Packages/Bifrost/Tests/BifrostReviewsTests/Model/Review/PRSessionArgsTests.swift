// The flags of the PR sessions (docs/behaviour/reviews.md, "PR sessions"): Claude Code enforces
// what a session can do, so the argv is pinned exactly.
import BifrostSessions
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the flags of the PR sessions", .timeLimit(.minutes(1)))
struct PRSessionArgsTests {
    private let input = URL(filePath: "/r/repos/o/r/.bifrost-io/7", directoryHint: .isDirectory)
    private let skills = URL(filePath: "/App/bifrost-skills", directoryHint: .isDirectory)

    // A review session has no shell, no web tool and no MCP server: only the read tools and the
    // write of its result file, in the mode auto, with no hook and no statusline.
    @Test func theReviewSessionHasNoShellAndNoOutsideTool() {
        let args = PRSessionArgs.review(
            name: "repo-7-review", model: .standard, inputFolder: input, skills: skills,
            prompt: "/bifrost-review bifrost-input=/r/repos/o/r/.bifrost-io/7/input.json")
        #expect(
            args == [
                "--bg", "--restricted", "--strict-mcp-config", "--tools", "Read", "Glob", "Grep",
                "Write", "Skill", "--permission-mode", "auto", "--add-dir",
                "/r/repos/o/r/.bifrost-io/7", "--plugin-dir", "/App/bifrost-skills",
                "--settings",
                #"{"statusLine":{"type":"command","command":"true"},"disableAllHooks":true}"#,
                "--name", "repo-7-review",
                "/bifrost-review bifrost-input=/r/repos/o/r/.bifrost-io/7/input.json",
            ])
        for tool in ["Bash", "WebFetch", "WebSearch", "Edit", "Agent", "--disallowedTools"] {
            #expect(!args.contains(tool), "\(tool)")
        }
    }

    // The model goes before the name, and the prompt is last.
    @Test func theModelComesBeforeTheName() {
        let review = PRSessionArgs.review(
            name: "repo-7-review", model: .haiku, inputFolder: input, skills: skills,
            prompt: "/bifrost-review bifrost-input=/x")
        #expect(Array(review.suffix(5)) == [
            "--model", "haiku", "--name", "repo-7-review", "/bifrost-review bifrost-input=/x",
        ])
        let request = PRSessionArgs.request(
            name: "repo-7-request", model: .opus, inputFolder: input, skills: skills,
            settings: "{}", prompt: "/bifrost-resolve-comments")
        #expect(
            request == [
                "--bg", "--restricted", "--strict-mcp-config", "--tools", "Bash",
                "Read", "Glob", "Grep", "Edit", "Write", "Skill", "--permission-mode", "auto",
                "--add-dir", "/r/repos/o/r/.bifrost-io/7", "--plugin-dir", "/App/bifrost-skills",
                "--settings", "{}", "--model", "opus", "--name", "repo-7-request",
                "/bifrost-resolve-comments",
            ])
        // --restricted keeps the file tools in the working folders and loads no settings file.
        #expect(!request.contains("--setting-sources"))
    }

    // The prompt names the input file, also a path with a space.
    @Test func thePromptNamesTheInputFile() {
        let file = URL(filePath: "/r/my repos/input.json", directoryHint: .notDirectory)
        #expect(
            PRSessionArgs.reviewPrompt(file)
                == "/bifrost-review bifrost-input=/r/my repos/input.json")
        #expect(
            PRSessionArgs.requestPrompt(file)
                == "/bifrost-resolve-comments bifrost-input=/r/my repos/input.json")
    }
}
