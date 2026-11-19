// The path rule of a fix commit (docs/behaviour/reviews.md, "Safety"). Each compare ignores case,
// because the default APFS volume ignores it.
import Testing

@testable import BifrostReviews

@Suite("the path rule of a fix commit", .timeLimit(.minutes(1)))
struct CommitFileRuleTests {
    @Test func aWorkflowFileIsNeverCommitted() {
        let paths = [
            ".github/workflows/ci.yml", ".GitHub/Workflows/x.yml", ".github/actions/a/action.yml",
            ".GITHUB/ACTIONS/b.yml", ".github/workflows", ".github/wor\u{212A}flows/x.yml",
        ]
        for path in paths {
            #expect(CommitFileRule.pathRefusal(path) == .workflow, "\(path.debugDescription)")
        }
        // Only the folders at the root run on GitHub.
        let others = [
            "src/.github/workflows/ci.yml", ".github/CODEOWNERS", ".github/dependabot.yml",
        ]
        for path in others {
            #expect(CommitFileRule.pathRefusal(path) == nil, "\(path.debugDescription)")
        }
    }

    @Test func aClaudeFolderAtAnyDepthIsNeverCommitted() {
        let paths = [
            ".claude/settings.json", "src/.claude/x", ".Claude/x", "a/b/.CLAUDE",
            ".cla\u{200B}ude/x",
        ]
        for path in paths {
            #expect(CommitFileRule.pathRefusal(path) == .claudeFolder, "\(path.debugDescription)")
        }
        for path in ["claude/x", ".claude.json", "src/.claudes/x", "CLAUDE.md"] {
            #expect(CommitFileRule.pathRefusal(path) == nil, "\(path.debugDescription)")
        }
    }

    @Test func aGitPathIsNeverCommitted() {
        let paths = [
            ".git/config", "a/.git/hooks/x", ".GIT/config", ".Git", "sub/.git", ".g\u{200C}it/x",
        ]
        for path in paths {
            #expect(CommitFileRule.pathRefusal(path) == .gitFolder, "\(path.debugDescription)")
        }
        for path in [".gitignore", ".gitattributes", ".github/CODEOWNERS", "a.git/x"] {
            #expect(CommitFileRule.pathRefusal(path) == nil, "\(path.debugDescription)")
        }
    }

    @Test func aPathOutsideTheWorktreeIsNeverCommitted() {
        let paths = [
            "", "/etc/passwd", "../x", "a/../../x", "a/..", "-A", "a/-x", "--force", "a//b", "a/",
            "./a", "a/./b",
        ]
        for path in paths {
            #expect(CommitFileRule.pathRefusal(path) == .outside, "\(path.debugDescription)")
        }
        for path in ["src/a.swift", "a..b/c", "a-b/c", "README.md", "x.y/z"] {
            #expect(CommitFileRule.pathRefusal(path) == nil, "\(path.debugDescription)")
        }
    }

    // .gitmodules at the root gives the addresses of the submodules: code that runs elsewhere.
    @Test func theSubmoduleFileIsNeverCommitted() {
        for path in [".gitmodules", ".GitModules", ".git\u{200B}modules"] {
            #expect(CommitFileRule.pathRefusal(path) == .submodule, "\(path.debugDescription)")
        }
        for path in ["sub/.gitmodules", ".gitmodules.bak", "gitmodules"] {
            #expect(CommitFileRule.pathRefusal(path) == nil, "\(path.debugDescription)")
        }
    }

    @Test func theLimitsAreOneAndFourMiB() {
        #expect(CommitFileRule.maxFileBytes == 1_048_576)
        #expect(CommitFileRule.maxSignedBytes == 4 * 1_048_576)
    }
}
