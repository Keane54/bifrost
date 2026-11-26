import BifrostFoundation
import BifrostLive
import BifrostTestSupport
import Foundation
import Testing

// The parse of the frontmatter of a SKILL.md and the group of a skill
// (docs/behaviour/skills.md, The skill files), and the parse of each skill file of the repo.

// A SKILL.md with the fields in their order, then the body lines.
private func skillText(_ fields: [(String, String)], bodyLines: Int = 1) -> String {
    let front = fields.map { "\($0.0): \($0.1)" }
    let body = Array(repeating: "Body.", count: bodyLines)
    return (["---"] + front + ["---"] + body).joined(separator: "\n")
}

private func fields(_ text: String) throws -> [String: SkillField] {
    try SkillCheck.parse(text).get()
}

@Suite("Skill check")
struct SkillCheckTests {
    @Test func readsPlainDoubleQuotedAndSingleQuotedValues() throws {
        #expect(try fields("---\ndescription: \"say \\\"hi\\\"\"\n---\n")["description"]
            == .text("say \"hi\""))
        #expect(
            try fields("---\ndescription: \"a \\\\ b\"\n---\n")["description"] == .text("a \\ b"))
        #expect(try fields("---\ndescription: 'it''s'\n---\n")["description"] == .text("it's"))
        #expect(try fields("---\ndescription: plain text\n---\n")["description"]
            == .text("plain text"))
        #expect(try fields("---\nargument-hint: \"[path]\"\n---\n")["argument-hint"]
            == .text("[path]"))
    }

    @Test func trimsTheWhiteSpaceAroundAValue() throws {
        #expect(try fields("---\ndescription:   a b \t\n---\n")["description"] == .text("a b"))
        #expect(try fields("---\ndescription: \u{A0}a\u{FEFF}\n---\n")["description"] == .text("a"))
    }

    @Test func aKeyWithNoValueIsAnEmptyText() throws {
        #expect(try fields("---\ndescription:\n---\n")["description"] == .text(""))
        #expect(try fields("---\ndescription: \n---\n")["description"] == .text(""))
    }

    @Test func readsABooleanFieldAsABoolean() throws {
        #expect(try fields("---\ndisable-model-invocation: true\n---\n")["disable-model-invocation"]
            == .flag(true))
        #expect(try fields("---\nbackground: false\n---\n")["background"] == .flag(false))
        #expect(try fields("---\nuser-invocable: true\n---\n")["user-invocable"] == .flag(true))
        #expect(try fields("---\nname: true\n---\n")["name"] == .text("true"))
    }

    @Test func countsTheLinesOfTheFile() {
        let text = skillText([("description", "x")], bodyLines: 3)
        #expect(SkillCheck.lines(of: text).count == 6)
        #expect(SkillCheck.lines(of: text + "\n").count == 6)
        #expect(SkillCheck.lines(of: text + "\n\n").count == 7)
        #expect(SkillCheck.lines(of: "").isEmpty)
    }

    @Test(
        arguments: [
            ("---\ndescription: x\nBody", SkillParseError.noClosingMarker),
            ("description: x\n---\n", .noOpeningMarker),
            ("", .noOpeningMarker),
            ("---\ndescription: a: b\n---\n", .needsQuotes("description")),
            ("---\ndescription: ab:\n---\n", .needsQuotes("description")),
            ("---\ndescription: a #b\n---\n", .needsQuotes("description")),
            ("---\ndescription: [a]\n---\n", .reservedFirstCharacter("description")),
            ("---\ndescription: {a}\n---\n", .reservedFirstCharacter("description")),
            ("---\ndescription: > a\n---\n", .reservedFirstCharacter("description")),
            ("---\ndescription: | a\n---\n", .reservedFirstCharacter("description")),
            ("---\ndescription: - a\n---\n", .reservedFirstCharacter("description")),
            ("---\ndescription: `a`\n---\n", .reservedFirstCharacter("description")),
            ("---\ndescription: a\ndescription: b\n---\n", .keyTwice("description")),
            ("---\ndescription: a\n\nname: b\n---\n", .blankLine(3)),
            ("---\ndescription: a\n  \nname: b\n---\n", .blankLine(3)),
            ("---\r\ndescription: a\r\n---\r\n", .crlfLineEnds),
            ("---\ndescription: a\r\n---\n", .crlfLineEnds),
            ("---\ndisable-model-invocation: yes\n---\n", .notABoolean("disable-model-invocation")),
            ("---\nbackground:\n---\n", .notABoolean("background")),
            ("---\ndescription: \"a\\nb\"\n---\n", .escapeNotAllowed("description")),
            ("---\ndescription: \"a\\\"\n---\n", .noClosingQuote("description")),
            ("---\ndescription: \"a\" b\n---\n", .textAfterClosingQuote("description")),
            ("---\ndescription: 'a' b\n---\n", .textAfterClosingQuote("description")),
            ("---\ndescription: 'a\n---\n", .noClosingQuote("description")),
            ("---\ndescription: a\n  more\n---\n", .notAKeyAndValue(3)),
            ("---\nDescription: a\n---\n", .notAKeyAndValue(2)),
            ("---\ndescription:a\n---\n", .notAKeyAndValue(2)),
            ("---\ndescription: a\u{2028}b\n---\n", .notAKeyAndValue(2)),
        ])
    func doesNotParse(text: String, reason: SkillParseError) {
        #expect(SkillCheck.parse(text) == .failure(reason))
    }

    @Test func aCombiningMarkDoesNotHideAQuote() throws {
        // As one Character, a quote and a combining acute accent are not a quote, and a space
        // and a combining mark are not a space. As Unicode scalars, the value still starts with
        // a quote, and ": " is still in the value.
        #expect(try fields("---\ndescription: \"\u{301}a\"\n---\n")["description"]
            == .text("\u{301}a"))
        #expect(
            SkillCheck.parse("---\ndescription: a: \u{301}b\n---\n")
                == .failure(.needsQuotes("description")))
    }

    @Test func mapsTheBooleanToAGroup() {
        #expect(SkillCheck.group(["disable-model-invocation": .flag(true)]) == .calledByName)
        #expect(SkillCheck.group(["disable-model-invocation": .flag(false)]) == .listed)
        #expect(SkillCheck.group([:]) == nil)
        #expect(SkillGroup.calledByName.rawValue == "called-by-name")
        #expect(SkillGroup.listed.rawValue == "listed")
    }

    // The skills folder of the repo, as the app bundles it. A new skill, or a skill that changes
    // its group, changes this list.
    @Test func eachSkillFileOfTheRepoParsesWithItsGroup() throws {
        let skills = try Repo.root().appending(path: "App/Bifrost/Resources/bifrost-skills/skills")
        let folders = try FileManager.default
            .contentsOfDirectory(atPath: skills.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }.sorted()
        let expected: [String: SkillGroup] = [
            "bifrost-daily-update": .calledByName, "bifrost-fix-ci": .calledByName,
            "bifrost-grill": .listed, "bifrost-hand-over": .calledByName,
            "bifrost-humanise": .listed, "bifrost-resolve-comments": .calledByName,
            "bifrost-resolve-conflicts": .calledByName, "bifrost-review": .calledByName,
        ]
        #expect(folders == expected.keys.sorted())
        for folder in folders {
            let text = try String(
                contentsOf: skills.appending(path: "\(folder)/SKILL.md"), encoding: .utf8)
            switch SkillCheck.parse(text) {
            case .success(let fields):
                #expect(SkillCheck.group(fields) == expected[folder], "\(folder)")
                #expect(fields["name"] == .text(folder), "\(folder)")
            case .failure(let reason):
                Issue.record("\(folder)/SKILL.md: \(reason.message)")
            }
        }
    }

    // The limits of the skills plugin of the repo. Claude Code adds the description and the
    // when_to_use text of each listed skill to each session, so the texts stay short. The counts
    // are UTF-16 units, the stricter count.
    @Test func theSkillsPluginOfTheRepoKeepsItsLimits() throws {
        let plugin = try Repo.root().appending(path: "App/Bifrost/Resources/bifrost-skills")
        let skills = plugin.appending(path: "skills")
        let allowed: Set<String> = [
            "name", "description", "when_to_use", "argument-hint", "arguments",
            "disable-model-invocation", "user-invocable", "allowed-tools", "disallowed-tools",
            "model", "effort", "context", "agent", "background", "paths", "shell", "license",
            "compatibility",
        ]
        var listedTotal = 0
        let folders = try FileManager.default
            .contentsOfDirectory(atPath: skills.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }
        for folder in folders {
            let text = try String(
                contentsOf: skills.appending(path: "\(folder)/SKILL.md"), encoding: .utf8)
            let fields = try SkillCheck.parse(text).get()
            #expect(Set(fields.keys).isSubset(of: allowed), "\(folder): \(fields.keys.sorted())")
            func value(_ key: String) -> String {
                if case .text(let value)? = fields[key] { value } else { "" }
            }
            #expect(
                !value("description").trimmingCharacters(in: .whitespaces).isEmpty, "\(folder)")
            let length = value("description").utf16.count + value("when_to_use").utf16.count
            #expect(length <= 250, "\(folder): \(length) characters")
            #expect(SkillCheck.lines(of: text).count <= 500, "\(folder)")
            if SkillCheck.group(fields) == .listed { listedTotal += length }
        }
        #expect(listedTotal <= 1500, "the listed skills have \(listedTotal) characters")
        let manifest = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: plugin.appending(path: ".claude-plugin/plugin.json")))
        #expect(manifest.fields?["name"] == .string("bifrost"))
        #expect(manifest.fields?["hooks"] == nil)
        #expect(!FileManager.default.fileExists(
            atPath: plugin.appending(path: "hooks/hooks.json").path(percentEncoded: false)))
    }
}
