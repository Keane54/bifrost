import Foundation
import Testing

@testable import BifrostSessions

// A hook of the user and a statusLine of the user.
private let userHookEntry = #"{"hooks":[{"command":"echo hi","type":"command"}]}"#
private let mine =
    #"{"command":"sh ~/.claude/statusline-command.sh","padding":0,"refreshInterval":1,"#
    + #""type":"command"}"#

@Suite("the plan of the settings edit", .timeLimit(.minutes(1)))
struct SettingsPlanTests {
    @Test func checkInstallFindsAllTenRowsAndTheWrapperOfAnOldInstall() throws {
        #expect(SettingsPlan.hookRows.count == 10)
        let result = SettingsPlan.checkInstall(try oldInstalled())
        #expect(result.missingHooks.isEmpty)
        #expect(result.statusLineInstalled)
    }

    // A value of an unexpected type stays, and no check traps on it.
    @Test(arguments: [
        #"{"hooks":"x","statusLine":"y"}"#,
        #"{"hooks":["x"],"statusLine":["y"]}"#,
        #"{"hooks":null,"statusLine":null}"#,
        #"{"hooks":{"Stop":"x","Start":7,"End":null,"Odd":{}}}"#,
        #"{"hooks":{"Stop":[1,null,"x",[],{"hooks":"x"},{"hooks":[1,null,"x",{"command":7}]}]}}"#,
        #"{"statusLine":{"command":7}}"#,
        #"{"statusLine":{"command":["~/.bifrost/bin/bifrost-statusline"]}}"#,
    ])
    func oddValuesStayAsTheyAre(_ text: String) throws {
        let odd = try settings(text)
        #expect(SettingsPlan.planUninstall(odd, original: nil) == odd)
        #expect(!SettingsPlan.hasBifrostEntry(odd))
        #expect(!SettingsPlan.checkInstall(odd).statusLineInstalled)
        #expect(SettingsPlan.checkInstall(odd).missingHooks.count == 10)
    }

    @Test func planUninstallKeepsAnEmptyEventList() throws {
        let empty = try settings(#"{"hooks":{"Stop":[]}}"#)
        #expect(SettingsPlan.planUninstall(empty, original: nil) == empty)
    }

    @Test func planUninstallRemovesOnlyBifrostHooksAndRestoresTheStatusLine() throws {
        let base = try settings(
            #"{"hooks":{"UserPromptSubmit":[\#(userHookEntry)]},"model":"x","#
                + #""statusLine":\#(mine)}"#)
        let planned = SettingsPlan.planUninstall(
            try oldInstalled(base), original: try settings(mine))
        #expect(planned == base)
    }

    @Test func planUninstallRemovesTheHooksKeyAndTheStatusLineWhenNothingElseWasThere() throws {
        #expect(SettingsPlan.planUninstall(try oldInstalled(), original: nil).text == "{}\n")
    }

    @Test func planUninstallKeepsAStatusLineThatIsNotTheWrapper() throws {
        var old = try oldInstalled()
        old.setValue(try jsonValue(mine), forKey: "statusLine")
        let planned = SettingsPlan.planUninstall(old, original: nil)
        #expect(planned["statusLine"] == (try jsonValue(mine)))
    }

    // An entry with a hook of the user and a Bifrost hook keeps the hook of the user and its own
    // key order.
    @Test func planUninstallRemovesOnlyTheBifrostHookFromAMixedEntry() throws {
        let mixed = try settings(
            #"{"hooks":{"PostToolUse":[{"hooks":[{"command":"echo hi","type":"command"},"#
                + #"\#(bifrostHookJSON),{"command":"echo bye","type":"command"}],"#
                + #""matcher":"*"}]}}"#)
        #expect(
            SettingsPlan.planUninstall(mixed, original: nil)
                == (try settings(
                    #"{"hooks":{"PostToolUse":[{"hooks":[{"command":"echo hi","type":"command"},"#
                        + #"{"command":"echo bye","type":"command"}],"matcher":"*"}]}}"#)))
    }

    // A Bifrost hook goes under each event and each matcher, also one that the old install never
    // used. The entries of the user keep their order around it.
    @Test func planUninstallRemovesBifrostHooksUnderEachEventAndMatcher() throws {
        let hook = bifrostHookJSON
        let before = try settings(
            #"{"hooks":{"Custom":[{"matcher":"Bash","hooks":[\#(hook)]}],"#
                + #""PreToolUse":[{"matcher":"A","hooks":[{"command":"a"}]},"#
                + #"{"matcher":"Write","hooks":[\#(hook),\#(hook)]},"#
                + #"{"hooks":[{"command":"b"}],"matcher":"B"}],"#
                + #""Stop":[{"hooks":[\#(hook)],"matcher":null}]}}"#)
        #expect(
            SettingsPlan.planUninstall(before, original: nil)
                == (try settings(
                    #"{"hooks":{"PreToolUse":[{"matcher":"A","hooks":[{"command":"a"}]},"#
                        + #"{"hooks":[{"command":"b"}],"matcher":"B"}]}}"#)))
    }

    // The keys of the settings, of the hooks and of each entry keep their places, and the original
    // statusLine takes the place of the wrapper, with its own key order and number texts.
    @Test func thePlanKeepsTheKeyOrder() throws {
        let installed = try settings(
            #"{"statusLine":\#(wrapperJSON),"env":{"Z":"1","A":"2"},"#
                + #""hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"},"#
                + #"\#(bifrostHookJSON)]}],"#
                + #""SessionStart":[{"hooks":[\#(bifrostHookJSON)]}],"#
                + #""Notification":[{"hooks":[{"command":"n"}],"matcher":"x"}]},"model":"opus"}"#)
        let original = try settings(#"{"type":"command","refreshInterval":1.0,"command":"mine"}"#)
        #expect(
            SettingsPlan.planUninstall(installed, original: original).text == """
                {
                  "statusLine": {
                    "type": "command",
                    "refreshInterval": 1.0,
                    "command": "mine"
                  },
                  "env": {
                    "Z": "1",
                    "A": "2"
                  },
                  "hooks": {
                    "Stop": [
                      {
                        "hooks": [
                          {
                            "type": "command",
                            "command": "mine"
                          }
                        ]
                      }
                    ],
                    "Notification": [
                      {
                        "hooks": [
                          {
                            "command": "n"
                          }
                        ],
                        "matcher": "x"
                      }
                    ]
                  },
                  "model": "opus"
                }

                """)
    }

    // The command compares by value, so an escape in the file still names the Bifrost hook. A
    // command with another text is not a Bifrost hook.
    @Test func theCommandComparesByValue() throws {
        let escaped = try settings(
            #"{"hooks":{"Stop":[{"hooks":[{"command":"~\/.bifrost\/bin\/bifrost-hook"}]}]},"#
                + #""statusLine":{"command":"\u007e/.bifrost/bin/bifrost-statusline"}}"#)
        #expect(SettingsPlan.hasBifrostEntry(escaped))
        #expect(SettingsPlan.planUninstall(escaped, original: nil).text == "{}\n")
        let other = try settings(
            #"{"hooks":{"Stop":[{"hooks":[{"command":"~/.bifrost/bin/bifrost-hook "}]}]},"#
                + #""statusLine":{"command":"~/.bifrost/bin/BIFROST-statusline"}}"#)
        #expect(!SettingsPlan.hasBifrostEntry(other))
        #expect(SettingsPlan.planUninstall(other, original: nil) == other)
    }

    // The plan takes one pass over the events. With a scan for each event, 100,000 events would
    // take minutes and go past the time limit of the suite.
    @Test func manyEventsTakeOnePass() throws {
        let hook = #"[{"hooks":[\#(bifrostHookJSON)]}]"#
        let user = #"[{"hooks":[{"command":"mine"}]}]"#
        let members = (0..<100_000).map { #""e\#($0)":\#($0 % 2 == 0 ? hook : user)"# }
        let many = try settings(#"{"hooks":{\#(members.joined(separator: ","))}}"#)
        let planned = SettingsPlan.planUninstall(many, original: nil)
        let events = try #require(planned["hooks"]?.object)
        #expect(events.members.count == 50_000)
        #expect(events.members.first?.key.raw == "e1")
        #expect(events.members.last?.key.raw == "e99999")
    }

    @Test func checkInstallNamesTheMissingRows() throws {
        var old = try oldInstalled()
        var hooks = try #require(old["hooks"]?.object)
        hooks.removeValue(forKey: "Notification")
        old.setValue(.object(hooks), forKey: "hooks")
        #expect(
            SettingsPlan.checkInstall(old).missingHooks == [
                "Notification:permission_prompt", "Notification:idle_prompt",
            ])
    }

    // A row needs the same matcher: a row with no matcher does not take an entry with a matcher,
    // and a row with a matcher needs that matcher as a text.
    @Test func checkInstallDoesNotTakeAHookWithAnotherMatcher() throws {
        let hook = bifrostHookJSON
        let other = try settings(#"{"hooks":{"Stop":[{"hooks":[\#(hook)],"matcher":"x"}]}}"#)
        #expect(SettingsPlan.checkInstall(other).missingHooks.contains("Stop"))
        #expect(!SettingsPlan.checkInstall(other).statusLineInstalled)
        let empty = try settings(#"{"hooks":{"Stop":[{"hooks":[\#(hook)],"matcher":""}]}}"#)
        #expect(SettingsPlan.checkInstall(empty).missingHooks.contains("Stop"))
        let null = try settings(
            #"{"hooks":{"PostToolUse":[{"hooks":[\#(bifrostHookJSON)],"matcher":null}]}}"#)
        #expect(SettingsPlan.checkInstall(null).missingHooks.contains("PostToolUse:*"))
        let star = try settings(
            #"{"hooks":{"PostToolUse":[{"hooks":[\#(bifrostHookJSON)],"matcher":"*"}]}}"#)
        #expect(!SettingsPlan.checkInstall(star).missingHooks.contains("PostToolUse:*"))
    }

    @Test(arguments: [
        "{}",
        #"{"hooks":{}}"#,
        #"{"hooks":"x"}"#,
        #"{"hooks":{"Stop":"x"}}"#,
        #"{"hooks":{"Stop":[{"hooks":[{"command":"mine","type":"command"}]}]}}"#,
        #"{"hooks":{"Stop":[{"hooks":[\#(bifrostHookJSON)]}]}}"#,
        #"{"hooks":{"PreToolUse":[{"hooks":[\#(bifrostHookJSON)],"matcher":"Bash"}]}}"#,
        #"{"hooks":{"Custom":[{"hooks":[{"command":"mine"},\#(bifrostHookJSON)]}]}}"#,
        #"{"hooks":{"Stop":[{"hook":[\#(bifrostHookJSON)]}]}}"#,
        #"{"hooks":{"Stop":[[\#(bifrostHookJSON)]]}}"#,
        #"{"statusLine":{"command":"mine","type":"command"}}"#,
        #"{"statusLine":\#(wrapperJSON)}"#,
        #"{"statusLine":{"command":"~/.bifrost/bin/bifrost-statusline","padding":2,"x":[1]}}"#,
    ])
    func hasBifrostEntryIsTrueExactlyWhenThePlanChangesTheSettings(_ text: String) throws {
        let document = try settings(text)
        let changes = SettingsPlan.planUninstall(document, original: nil) != document
        #expect(SettingsPlan.hasBifrostEntry(document) == changes)
    }

    @Test func anOldInstallHasABifrostEntry() throws {
        #expect(SettingsPlan.hasBifrostEntry(try oldInstalled()))
        let planned = SettingsPlan.planUninstall(try oldInstalled(), original: nil)
        #expect(!SettingsPlan.hasBifrostEntry(planned))
    }
}
