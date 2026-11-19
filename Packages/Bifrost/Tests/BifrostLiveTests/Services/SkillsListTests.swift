import BifrostFoundation
import BifrostLive
import BifrostTestSupport
import Foundation
import Testing

// The skills list of the skills folder of the app (docs/behaviour/skills.md, The skills list).
// Each test works in a TemporaryFolder.

private func put(_ base: URL, _ relative: String, _ text: String) throws {
    let file = base.appending(path: relative)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
}

// A SKILL.md with a name, a description and the group flag. With no flag, the skill has no
// group.
private func skill(_ name: String, _ flag: String?) -> String {
    let flagLine = flag.map { "disable-model-invocation: \($0)\n" } ?? ""
    return "---\nname: \(name)\ndescription: About \(name).\n\(flagLine)---\n\nBody\n"
}

// A source with two skills: bifrost-b (called by name) and bifrost-a (listed).
private func source(in folder: TemporaryFolder) throws -> URL {
    let source = folder.url.appending(path: "source")
    try put(source, ".claude-plugin/plugin.json", #"{"name":"bifrost"}"#)
    try put(source, "skills/bifrost-b/SKILL.md", skill("bifrost-b", "true"))
    try put(source, "skills/bifrost-a/SKILL.md", skill("bifrost-a", "false"))
    try put(source, "skills/bifrost-a/rules.md", "rules")
    return source
}

private let twoSkills = [
    SkillInfo(name: "bifrost-a", description: "About bifrost-a.", group: .listed),
    SkillInfo(name: "bifrost-b", description: "About bifrost-b.", group: .calledByName),
]

@Suite("Skills list")
struct SkillsListTests {
    @Test func givesTheNameTheDescriptionAndTheGroupSortedByName() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        #expect(try await SkillsList.list(try source(in: folder)) == twoSkills)
    }

    @Test func leavesOutAFolderWithNoSkillFileOrAFrontmatterThatDoesNotParse() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = try source(in: folder)
        try put(source, "skills/bifrost-c/rules.md", "no skill file")
        try put(source, "skills/bifrost-d/SKILL.md", "no frontmatter")
        try put(source, "skills/bifrost-e/SKILL.md", skill("bifrost-e", nil))
        try put(source, "skills/notes.md", "a file, not a folder")
        #expect(try await SkillsList.list(source) == twoSkills)
    }

    @Test func aMissingOrEmptyNameGivesTheFolderNameAndAMissingDescriptionGivesNoText()
        async throws
    {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = folder.url.appending(path: "source")
        try put(source, "skills/bifrost-x/SKILL.md", "---\ndisable-model-invocation: true\n---\n")
        try put(
            source, "skills/bifrost-y/SKILL.md",
            "---\nname:\ndescription: Why.\ndisable-model-invocation: false\n---\n")
        #expect(
            try await SkillsList.list(source) == [
                SkillInfo(name: "bifrost-x", description: "", group: .calledByName),
                SkillInfo(name: "bifrost-y", description: "Why.", group: .listed),
            ])
    }

    @Test func aLinkIsNotASkill() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let source = try source(in: folder)
        let outside = folder.url.appending(path: "outside")
        try put(outside, "bifrost-z/SKILL.md", skill("bifrost-z", "true"))
        try put(outside, "bifrost-w.md", skill("bifrost-w", "true"))
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "skills/bifrost-z"),
            withDestinationURL: outside.appending(path: "bifrost-z"))
        try FileManager.default.createDirectory(
            at: source.appending(path: "skills/bifrost-w"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "skills/bifrost-w/SKILL.md"),
            withDestinationURL: outside.appending(path: "bifrost-w.md"))
        #expect(try await SkillsList.list(source) == twoSkills)
    }

    @Test func throwsWhenTheSkillsFolderIsMissing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        await #expect(throws: SyncFailure.self) {
            try await SkillsList.list(folder.url.appending(path: "none"))
        }
    }
}
