// The form of the New session dialog (docs/behaviour/actions.md, "New session"): the first
// values, the suggested name, the changes of the fields, the spec and the worktree option.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostSessions

private func form(_ history: History = .empty) -> NewSessionForm {
    NewSessionForm.initial(history, suffix: "a1b2")
}

private func applying(_ action: FormAction, to form: NewSessionForm) -> NewSessionForm {
    var form = form
    form.apply(action)
    return form
}

// A generator that gives the same value each time.
private struct FixedGenerator: RandomNumberGenerator {
    var value: UInt64
    mutating func next() -> UInt64 { value }
}

@Suite("the New session form")
struct NewSessionFormTests {
    @Test func theSuggestedNameIsTheFolderNameAndTheSuffix() {
        #expect(
            NewSessionForm.suggestName("/Users/o/Developer/bifrost", suffix: "a1b2")
                == "bifrost-a1b2")
        #expect(NewSessionForm.suggestName("/p/app/", suffix: "a1b2") == "app-a1b2")
        #expect(NewSessionForm.suggestName("/", suffix: "a1b2") == "session-a1b2")
        #expect(NewSessionForm.suggestName("", suffix: "a1b2") == "session-a1b2")
    }

    // The folder part has at most 40 Characters, so an emoji counts as one.
    @Test func theFolderPartOfTheSuggestedNameHasAtMost40Characters() {
        let long = String(repeating: "x", count: 60)
        #expect(
            NewSessionForm.suggestName("/\(long)", suffix: "a1b2")
                == String(repeating: "x", count: 40) + "-a1b2")
        let emoji = String(repeating: "🚀", count: 50)
        #expect(
            NewSessionForm.suggestName("/p/\(emoji)", suffix: "a1b2")
                == String(repeating: "🚀", count: 40) + "-a1b2")
    }

    @Test func aNewSuffixIsFourLowerCaseHexDigits() {
        var generator = FixedGenerator(value: 0xAB0F)
        #expect(NewSessionForm.newSuffix(using: &generator) == "ab0f")
        generator.value = 0x0001
        #expect(NewSessionForm.newSuffix(using: &generator) == "0001")
        let suffix = NewSessionForm.newSuffix()
        #expect(suffix.count == 4)
        #expect(suffix.allSatisfy { "0123456789abcdef".contains($0) })
    }

    // The folder part loses the hidden characters of a name, so the spec check accepts the
    // suggestion. A folder name of only hidden characters counts as no part.
    @Test func theSuggestedNameHasNoHiddenCharacters() {
        let name = NewSessionForm.suggestName("/p/a\u{202E}p\u{200B}p\u{7}", suffix: "a1b2")
        #expect(name == "app-a1b2")
        let spec = NewSessionSpec.check(
            cwd: "/p", name: name, model: .standard, permissionMode: nil, prompt: "",
            worktree: false)
        #expect((try? spec.get())?.name == "app-a1b2")
        #expect(NewSessionForm.suggestName("/p/\u{200B}\u{202E}", suffix: "a1b2") == "session-a1b2")
    }

    @Test func theFirstValuesComeFromTheHistory() {
        let history = History(recentDirs: ["/p/app", "/q"], model: .haiku, permissionMode: .plan)
        let first = form(history)
        #expect(first.cwd == "/p/app")
        #expect(first.model == .haiku)
        #expect(first.permissionMode == .plan)
        #expect(first.name == "app-a1b2")
        #expect(!first.nameEdited)
        #expect(first.prompt.isEmpty)
        #expect(!first.worktree)
    }

    @Test func anEmptyHistoryGivesNoFolderAndTheDefaults() {
        let first = form()
        #expect(first.cwd.isEmpty)
        #expect(first.name == "session-a1b2")
        #expect(first.model == .standard)
        #expect(first.permissionMode == nil)
    }

    @Test func aNewFolderChangesASuggestedNameButNotAnEditedName() {
        let start = form(History(recentDirs: ["/p/app"]))
        #expect(applying(.cwd("/p/web"), to: start).name == "web-a1b2")
        let edited = applying(.name("mine"), to: start)
        #expect(edited.nameEdited)
        #expect(applying(.cwd("/p/web"), to: edited).name == "mine")
        #expect(applying(.cwd("/p/app"), to: start) == start)
    }

    // A name that the user types counts as edited, also when it is the suggested name.
    @Test func eachNameChangeMarksTheNameAsEdited() {
        let start = form(History(recentDirs: ["/p/app"]))
        let same = applying(.name("app-a1b2"), to: start)
        #expect(same.nameEdited)
        #expect(applying(.cwd("/p/web"), to: same).name == "app-a1b2")
    }

    @Test func aNewFolderTurnsTheWorktreeOptionOff() {
        let on = applying(.worktree(true), to: form())
        #expect(on.worktree)
        #expect(!applying(.cwd("/x"), to: on).worktree)
        // The same folder changes nothing.
        let sameFolder = applying(.worktree(true), to: form(History(recentDirs: ["/x"])))
        #expect(applying(.cwd("/x"), to: sameFolder).worktree)
    }

    @Test func theOtherActionsChangeOneField() {
        let start = form()
        #expect(applying(.model(.opus), to: start).model == .opus)
        #expect(applying(.mode(.plan), to: start).permissionMode == .plan)
        #expect(applying(.mode(nil), to: applying(.mode(.plan), to: start)).permissionMode == nil)
        #expect(applying(.prompt("hi"), to: start).prompt == "hi")
        #expect(applying(.model(.standard), to: start) == start)
        #expect(applying(.worktree(false), to: start) == start)
    }

    @Test func theSpecRefusesABadFormWithItsReason() {
        #expect(form().spec() == .failure(.noFolder))
        #expect(ActionRefusal.noFolder.message == "Choose a project folder.")
        let folder = applying(.cwd("/p/app"), to: form())
        #expect(applying(.name(" "), to: folder).spec() == .failure(.noName))
    }

    @Test func aGoodFormGivesItsSpec() throws {
        var good = applying(.cwd("/p/app"), to: form())
        good.apply(.prompt("fix the tests"))
        good.apply(.worktree(true))
        let spec = try good.spec().get()
        #expect(spec.cwd == "/p/app")
        #expect(spec.name == "app-a1b2")
        #expect(spec.prompt == "fix the tests")
        #expect(spec.worktree)
    }

    // The folder check and the worktree reason use the same rule.
    @Test func anAbsoluteFolderStartsWithASlashAfterTheTrim() {
        #expect(NewSessionForm.isAbsoluteDir("/p/app"))
        #expect(NewSessionForm.isAbsoluteDir(" /p/app"))
        #expect(!NewSessionForm.isAbsoluteDir("relative/path"))
        #expect(!NewSessionForm.isAbsoluteDir("  "))
        #expect(!NewSessionForm.isAbsoluteDir(""))
    }
}

@Suite("the worktree option of the New session form")
struct WorktreeOptionTests {
    private func reason(_ check: FolderCheck, cwd: String = "/p/app") -> String? {
        let state = NewSessionForm.worktreeState(cwd: cwd, check)
        #expect(state.enabled == (state.reason == nil))
        return state.reason
    }

    @Test func eachReasonAndOnForAGitFolder() {
        #expect(reason(.checking) == "Checking the folder...")
        #expect(reason(.failed) == "Bifrost couldn't check this folder.")
        #expect(reason(.done(DirInfo(kind: .missing, git: false))) == "This folder doesn't exist.")
        #expect(reason(.done(DirInfo(kind: .other, git: false))) == "This folder doesn't exist.")
        #expect(
            reason(.done(DirInfo(kind: .dir, git: false)))
                == "This folder isn't in a git repository, so it can't use a worktree.")
        #expect(reason(.done(DirInfo(kind: .dir, git: true))) == nil)
    }

    // No folder check runs for a folder that does not start with "/", so the reason must not
    // stay "Checking the folder...".
    @Test(arguments: ["relative/path", ".m0-sandbox", "", "  "])
    func aFolderThatIsNotAbsoluteGivesTheFolderReason(cwd: String) {
        for check in [FolderCheck.checking, .failed, .done(DirInfo(kind: .dir, git: true))] {
            #expect(reason(check, cwd: cwd) == "Choose a project folder.")
        }
    }

    @Test func aFolderWithSpaceBeforeItIsChecked() {
        #expect(reason(.checking, cwd: " /p/app") == "Checking the folder...")
    }
}
