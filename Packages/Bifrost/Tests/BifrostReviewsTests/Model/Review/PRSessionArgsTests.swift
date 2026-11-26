// The flags of the PR sessions (docs/behaviour/reviews.md, "PR sessions"): Claude Code enforces
// what a session can do, so the argv is pinned exactly.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the flags of the PR sessions", .testTimeLimit)
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

    // A resume passes no start flag: a resume with a flag starts a copy of the session with a
    // new session ID. The session restores the flags of its start (its saved options) by itself.
    @Test func theResumeArgsHoldNoStartFlag() {
        let id: SessionID = "dc56b1af-ac1e-45bc-b23d-369b4a25f190"
        #expect(
            PRSessionArgs.resume(id, prompt: "/bifrost-resolve-comments bifrost-input=/x")
                == [
                    "--bg", "--resume", "dc56b1af-ac1e-45bc-b23d-369b4a25f190",
                    "/bifrost-resolve-comments bifrost-input=/x",
                ])
    }

    // The profile is the same for each name, resume ID and prompt, and changes with each flag
    // or value that limits the session, for example the model or the settings.
    @Test func theProfileIgnoresTheNameTheResumeAndThePrompt() {
        func args(
            name: String = "repo-7-request", model: ModelChoice = .standard,
            settings: String = "{}", prompt: String = "/bifrost-resolve-comments a"
        ) -> [String] {
            PRSessionArgs.request(
                name: name, model: model, inputFolder: input, skills: skills, settings: settings,
                prompt: prompt)
        }
        let profile = PRSessionArgs.profile(args())
        #expect(profile.count == 64)
        #expect(profile.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(PRSessionArgs.profile(args(name: "repo-7-request-owner")) == profile)
        #expect(PRSessionArgs.profile(args(prompt: "/bifrost-resolve-comments b")) == profile)
        var resumed = args()
        resumed.insert(contentsOf: ["--resume", "dc56b1af-ac1e-45bc-b23d-369b4a25f190"], at: 1)
        #expect(PRSessionArgs.profile(resumed) == profile)
        #expect(PRSessionArgs.profile(args(model: .opus)) != profile)
        #expect(PRSessionArgs.profile(args(settings: #"{"a":1}"#)) != profile)
        // The arguments join with NUL, so two arguments never read as one.
        #expect(
            PRSessionArgs.profile(["a b", "c", "p"]) != PRSessionArgs.profile(["a", "b c", "p"]))
    }

    // The note of a resume (claude 2.1.328) must name the woken session and each limit of a
    // request session. Else Bifrost can't tell that the session kept its sandbox.
    @Test func theResumeNoteNamesTheSessionAndEachLimit() {
        let session: ShortID = "dc56b1af"
        let note =
            "note: woke session dc56b1af with its saved options (--restricted, "
            + "--strict-mcp-config, --tools, --permission-mode, --settings, --add-dir, "
            + "--plugin-dir, --name, --model).\nbackgrounded \u{B7} dc56b1af (idle)\n"
        #expect(PRSessionArgs.resumeNote(note, session: session) == .kept)

        let fewer =
            "note: woke session dc56b1af with its saved options (--restricted, "
            + "--strict-mcp-config, --tools, --permission-mode, --settings, --name, --model)."
        #expect(
            PRSessionArgs.resumeNote(fewer, session: session)
                == .missing(["--add-dir", "--plugin-dir"]))

        let other: ShortID = "4101c621"
        #expect(PRSessionArgs.resumeNote(note, session: other) == .otherSession(session))

        let copy =
            "background session c4dab742 keeps its own saved options, so the flags you passed "
            + "started a copy as 6840b5e4.\nbackgrounded \u{B7} 6840b5e4 (idle)\n"
        #expect(PRSessionArgs.resumeNote(copy, session: session) == .noNote)
        #expect(PRSessionArgs.resumeNote("", session: session) == .noNote)
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

    // A conflict round types its prompt into the request session of the PR: the conflict skill
    // and the input file of the round, also a path with a space.
    @Test func theConflictPromptNamesTheSkillAndTheInput() {
        let file = URL(
            filePath: "/r/my repos/input-7c1e0f8a2b5d.json", directoryHint: .notDirectory)
        #expect(
            PRSessionArgs.conflictPrompt(file)
                == "/bifrost-resolve-conflicts bifrost-input=/r/my repos/input-7c1e0f8a2b5d.json")
    }

    // A CI round types its prompt into the request session of the PR: the CI skill and the input
    // file of the round, also a path with a space.
    @Test func theCIPromptNamesTheSkillAndTheInput() {
        let file = URL(
            filePath: "/r/my repos/input-7c1e0f8a2b5d.json", directoryHint: .notDirectory)
        #expect(
            PRSessionArgs.ciPrompt(file)
                == "/bifrost-fix-ci bifrost-input=/r/my repos/input-7c1e0f8a2b5d.json")
    }
}
