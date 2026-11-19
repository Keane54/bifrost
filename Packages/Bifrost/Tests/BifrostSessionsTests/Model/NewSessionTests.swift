// The values of the New session dialog and the checks on them (docs/behaviour/actions.md, "New
// session"): the clean values, the reason of each bad value, the claude command names, the name
// of a worktree and the model options.
import BifrostFoundation
import Foundation
import Testing

@testable import BifrostSessions

// Check a spec with good values. A test gives only the values that it changes.
private func check(
    cwd: String = "/p", name: String = "bifrost-test-n", model: ModelChoice = .haiku,
    mode: PermissionMode? = .plan, prompt: String = "Reply", worktree: Bool = false
) -> Result<NewSessionSpec, ActionRefusal> {
    NewSessionSpec.check(
        cwd: cwd, name: name, model: model, permissionMode: mode, prompt: prompt,
        worktree: worktree)
}

private func refusal(_ result: Result<NewSessionSpec, ActionRefusal>) -> ActionRefusal? {
    if case .failure(let refusal) = result { refusal } else { nil }
}

// The command names and aliases in the "Commands:" part of a claude help text. A name line
// starts with two spaces and a name. A longer indent is the next line of a description.
private func helpCommands(_ text: String) -> [String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let start = lines.firstIndex(where: { $0.trimmed() == "Commands:" }) else { return [] }
    var names: [String] = []
    for line in lines[(start + 1)...] {
        if line.trimmed().isEmpty || !line.hasPrefix(" ") { break }
        let pattern = #/  ([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)*)(?:\s|$).*/#
        if let match = line.wholeMatch(of: pattern) {
            names += match.output.1.split(separator: "|").map(String.init)
        }
    }
    return names
}

@Suite("the New session values")
struct NewSessionSpecTests {
    // The cwd loses its white space and its last "/", and the name and the prompt get the clean
    // of the session input (CR LF becomes LF, the control characters go) and the trim.
    @Test func aFullSpecGivesTheCleanValues() throws {
        let spec = try check(
            cwd: " /p/ ", name: "  n1\u{1B} ", prompt: " Reply\r\nnow\u{7} ", worktree: true
        ).get()
        #expect(spec.cwd == "/p" && spec.name == "n1" && spec.prompt == "Reply\nnow")
        #expect(spec.model == .haiku && spec.permissionMode == .plan && spec.worktree)
    }

    @Test func theDefaultsAndTheRootFolderStay() throws {
        let spec = try check(cwd: "/", model: .standard, mode: nil, prompt: "   ").get()
        #expect(spec.cwd == "/" && spec.name == "bifrost-test-n" && spec.prompt == "")
        #expect(spec.model == .standard && spec.permissionMode == nil && !spec.worktree)
    }

    @Test(arguments: [("/a/b//", "/a/b"), ("///", "/"), ("/a b/", "/a b"), (" /x ", "/x")])
    func theLastSlashesOfTheFolderGo(cwd: String, expected: String) throws {
        #expect(try check(cwd: cwd).get().cwd == expected)
    }

    @Test(
        "each bad value gives its reason, in the order of the checks",
        arguments: [
            (check(cwd: "p"), ActionRefusal.noFolder),
            (check(cwd: ""), .noFolder),
            (check(cwd: "  "), .noFolder),
            (check(cwd: "p", name: ""), .noFolder),
            (check(cwd: "/p\u{0}x"), .noFolder),
            (check(name: ""), .noName),
            (check(name: " \u{1B} "), .noName),
            (check(name: String(repeating: "n", count: 65)), .nameTooLong),
            (check(name: "a\nb"), .nameLines),
            (check(name: "a\r\nb"), .nameLines),
            (check(name: "a\rb"), .nameLines),
            (check(name: "a\tb"), .nameLines),
            (check(name: "a\u{2028}b"), .nameLines),
            (check(name: "a\u{2029}b"), .nameLines),
            (check(name: "a\u{200B}b"), .nameHidden),
            (check(name: "a\u{202E}b"), .nameHidden),
            (check(name: "a\u{2066}b"), .nameHidden),
            (check(name: "\u{FEFF}b"), .nameHidden),
            (check(name: "-\u{200B}b"), .nameHidden),
            (check(name: "-n"), .nameFlag),
            (check(name: "-n", prompt: "-x"), .nameFlag),
            (check(prompt: String(repeating: "p", count: InputPlan.maxText + 1)), .promptTooLong),
            (check(prompt: " -x"), .promptFlag),
            (check(prompt: "update"), .promptIsCommand),
            (check(prompt: " help\n"), .promptIsCommand),
            (check(prompt: "install"), .promptIsCommand),
        ])
    func badValue(result: Result<NewSessionSpec, ActionRefusal>, expected: ActionRefusal) {
        #expect(refusal(result) == expected)
    }

    // claude reads an argument as a flag when its first byte is "-". A combining mark after the
    // dash makes one Character of the two, and the check must still see the dash.
    @Test func aDashWithACombiningMarkIsStillAFlag() {
        #expect(refusal(check(name: "-\u{301}n")) == .nameFlag)
        #expect(refusal(check(prompt: "-\u{301}x")) == .promptFlag)
        #expect(refusal(check(cwd: "/\u{301}a")) == nil)
    }

    // The limits count Characters, as each limit of the app does: an emoji or a letter with a
    // combining mark counts as one.
    @Test(arguments: ["n", "😀", "e\u{301}"])
    func theLimitsCountCharacters(unit: String) {
        func text(_ count: Int) -> String { String(repeating: unit, count: count) }
        let longest = NewSessionSpec.maxName
        #expect(refusal(check(name: text(longest))) == nil)
        #expect(refusal(check(name: text(longest + 1))) == .nameTooLong)
        #expect(refusal(check(prompt: text(InputPlan.maxText))) == nil)
        #expect(refusal(check(prompt: text(InputPlan.maxText + 1))) == .promptTooLong)
    }

    // The limit counts the prompt after the clean and the trim.
    @Test func thePromptLimitCountsTheCleanText() {
        let text = String(repeating: "p", count: InputPlan.maxText)
        #expect(refusal(check(prompt: "  \(text)\u{1B}  ")) == nil)
    }

    @Test func eachReasonHasItsText() {
        let texts: [(ActionRefusal, String)] = [
            (.noFolder, "Choose a project folder."),
            (.noName, "Type a name."),
            (.nameTooLong, "The name is too long. The maximum is 64 characters."),
            (.nameLines, "The name has one line."),
            (.nameHidden, "A name can't hold control or hidden characters."),
            (.nameFlag, #"The name cannot start with "-"."#),
            (.promptTooLong, "The text is too long. The maximum is 20,000 characters."),
            (.promptFlag, #"The first prompt cannot start with "-"."#),
            (.promptIsCommand, "That prompt is also a Claude command name. Add a few more words."),
            (.dirMissing, "This folder doesn't exist."),
            (.noGit, "This folder isn't in a git repository, so it can't use a worktree."),
        ]
        for (refusal, text) in texts { #expect(refusal.message == text) }
        #expect(NewSessionRules.reasonChecking == "Checking the folder...")
        #expect(NewSessionRules.reasonCheckFailed == "Bifrost couldn't check this folder.")
    }
}

@Suite("the claude command names")
struct ClaudeCommandTests {
    // The fixture is the "Commands:" part of the claude --help text of Claude Code 2.1.318. The
    // list also keeps "help", the hidden commands and the names of older versions. An extra name
    // only refuses a one-word prompt, so the list can have more names than claude.
    @Test func theListHasEachCommandAndAliasOfTheHelpText() throws {
        let text = String(decoding: try Fixture.data("claude-commands.txt"), as: UTF8.self)
        let names = helpCommands(text)
        // A broken parse finds few names.
        #expect(names.count > 15)
        #expect(Set(["stop", "kill", "update", "upgrade", "rm"]).isSubset(of: names))
        #expect(names.filter { !NewSessionRules.claudeCommands.contains($0) } == [])
        let kept = ["config", "migrate-installer", "help"]
        #expect(Set(kept).isSubset(of: NewSessionRules.claudeCommands))
        #expect(Set(NewSessionRules.claudeCommands).count == NewSessionRules.claudeCommands.count)
    }

    @Test func theParseReadsTheHelpForm() {
        let help = """
            Usage: claude [options] [command] [prompt]
            Commands:
              mcp                     Configure and manage MCP servers
              install [options] [target]  Install Claude Code native build. Use [target]
                                      to specify version
              stop|kill <id>          Stop a background session

            Examples:
              claude agents
            """
        #expect(helpCommands(help) == ["mcp", "install", "stop", "kill"])
    }

    @Test(arguments: ["update", " help ", "stop", "kill", "rc", "rm", "migrate-installer"])
    func aWholeCommandNameMatchesAfterTheTrim(text: String) {
        #expect(NewSessionRules.isClaudeCommand(text))
    }

    @Test(arguments: ["update the docs", "Update", "stopped", "", "rm -rf", "help!"])
    func otherTextIsNoCommand(text: String) {
        #expect(!NewSessionRules.isClaudeCommand(text))
    }

    @Test func aPromptWithMoreWordsIsAccepted() {
        #expect(refusal(check(prompt: "update the docs")) == nil)
    }
}

@Suite("the name of a worktree")
struct WorktreeNameTests {
    // Each run of characters outside a-z and 0-9 becomes one "-", the ends lose their "-", the
    // name has at most 40 characters, and an empty result gives "session".
    @Test(
        arguments: [
            ("My Session_1!", "my-session-1"),
            ("---", "session"),
            ("", "session"),
            ("bifrost-test-wt", "bifrost-test-wt"),
            ("..a//b..", "a-b"),
            (String(repeating: "a", count: 39) + " b", String(repeating: "a", count: 39)),
            (String(repeating: "x", count: 50), String(repeating: "x", count: 40)),
            ("Café 😀 Ünïcode", "caf-n-code"),
            ("ÀÉÎ", "session"),
        ])
    func aNameThatGitAccepts(name: String, expected: String) {
        #expect(NewSessionRules.worktreeName(name) == expected)
    }
}

@Suite("the model options")
struct ModelOptionTests {
    @Test func theDialogNamesTheEmptyChoiceDefault() {
        let choices = NewSessionRules.modelChoices
        #expect(choices.map { $0.value } == [.standard, .opus, .sonnet, .haiku])
        #expect(choices.map { $0.label } == ["Default", "Opus", "Sonnet", "Haiku"])
    }

    @Test func aSettingsSelectNamesTheEmptyChoiceTheClaudeCodeDefault() {
        let options = NewSessionRules.modelOptions()
        #expect(options.map { $0.value } == [.standard, .opus, .sonnet, .haiku])
        #expect(options.map { $0.label } == ["Claude Code default", "Opus", "Sonnet", "Haiku"])
    }
}

@Suite("the model choice of a model ID")
struct ModelChoiceOfAnIDTests {
    // The model of a transcript or a usage line gives the model choice of its family.
    @Test func aModelIDGivesItsModelChoice() {
        #expect(ModelChoice(modelID: "claude-opus-5-5") == .opus)
        #expect(ModelChoice(modelID: "opus[1m]") == .opus)
        #expect(ModelChoice(modelID: "claude-sonnet-4-6-20260101") == .sonnet)
        #expect(ModelChoice(modelID: "Haiku") == .haiku)
        #expect(ModelChoice(modelID: "claude-fable-5-2") == nil)
        #expect(ModelChoice(modelID: "gpt-opus") == nil)
        #expect(ModelChoice(modelID: "") == nil)
    }
}
