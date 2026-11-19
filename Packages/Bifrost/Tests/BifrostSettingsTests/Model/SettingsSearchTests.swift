// The search of the Settings panel (docs/behaviour/settings.md, "The search"): the match of a
// text and of a key, the index of the sections, the hits, the texts, Esc and Cmd+F.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostKeyboard
@testable import BifrostSettings

// The key of a binding text.
private func key(_ text: String) -> KeyBinding {
    .chord(chord(text))
}

// The key rows of the default keys, with the plain labels.
private let defaultKeyRows: [SearchRow] = KeySlot.all.map { slot in
    SearchRow(id: slot.text, text: slot.label(.plain), key: KeyMap.defaults[slot])
}

@Suite("the match of a text")
struct TextMatchTests {
    @Test func eachWordOfTheQueryMatchesInAnyOrderAndCase() {
        #expect(SettingsSearch.textMatches("Row flash", "flash"))
        #expect(SettingsSearch.textMatches("Row flash", "FLASH row"))
        #expect(SettingsSearch.textMatches("Sound for a red box", "box  red"))
        #expect(SettingsSearch.textMatches(#"Default app for "Open project""#, "open proj"))
        #expect(!SettingsSearch.textMatches("Row flash", "flash sound"))
    }

    @Test func anEmptyQueryMatchesNothing() {
        #expect(!SettingsSearch.textMatches("Row flash", "   "))
        #expect(!SettingsSearch.textMatches("Row flash", ""))
    }
}

@Suite("the match of a key")
struct KeyMatchTests {
    @Test func theShownFormMatchesWithOrWithoutSpacesInAnyOrder() {
        #expect(SettingsSearch.keyMatches(key("Mod+Shift+T"), "⇧ ⌘ T"))
        #expect(SettingsSearch.keyMatches(key("Mod+Shift+T"), "⌘⇧T"))
        #expect(SettingsSearch.keyMatches(key("Mod+Alt+Shift+Backspace"), "⌥ ⇧ ⌘ ⌫"))
        #expect(SettingsSearch.keyMatches(key("Mod+Enter"), "⌘↵"))
    }

    @Test func aTypedFormMatchesWithSpacesOrWithPlus() {
        #expect(SettingsSearch.keyMatches(key("Mod+Shift+T"), "cmd shift t"))
        #expect(SettingsSearch.keyMatches(key("Mod+Shift+T"), "cmd+shift+t"))
        #expect(SettingsSearch.keyMatches(key("Mod+Shift+T"), "Command + Shift + T"))
        #expect(SettingsSearch.keyMatches(key("Mod+,"), "cmd+,"))
        #expect(SettingsSearch.keyMatches(key("Escape"), "esc"))
        #expect(SettingsSearch.keyMatches(key("Enter"), "return"))
        #expect(SettingsSearch.keyMatches(key("ArrowUp"), "up"))
    }

    @Test func oneModifierAloneMatchesByItsShortNameOrItsSymbol() {
        #expect(SettingsSearch.keyMatches(key("Mod+Control+1"), "ctrl"))
        #expect(SettingsSearch.keyMatches(key("Mod+Control+1"), "⌃"))
        #expect(SettingsSearch.keyMatches(key("Mod+Alt+Shift+Backspace"), "opt"))
        #expect(SettingsSearch.keyMatches(key("Mod+Alt+S"), "option"))
        #expect(!SettingsSearch.keyMatches(key("Mod+N"), "ctrl"))
    }

    // The list shows Ctrl as ⌃, which looks like the caret ^ of the keyboard.
    @Test func theCaretFindsAControlKey() {
        #expect(SettingsSearch.keyMatches(key("Mod+Control+1"), "^ ⌘ 1"))
        #expect(SettingsSearch.keyMatches(key("Mod+Control+1"), "^1"))
        #expect(SettingsSearch.keyMatches(key("Mod+Control+F"), "^"))
        #expect(!SettingsSearch.keyMatches(key("Mod+N"), "^"))
    }

    @Test func aSingleLetterMustBeTheKeyAndALongerWordCanStartAName() {
        #expect(!SettingsSearch.keyMatches(key("Mod+Shift+Tab"), "cmd shift t"))
        #expect(SettingsSearch.keyMatches(key("Mod+Shift+Tab"), "cmd shift ta"))
        #expect(!SettingsSearch.keyMatches(key("Mod+Shift+T"), "cmd shift ta"))
        #expect(!SettingsSearch.keyMatches(key("Mod+Shift+T"), "cmd shift r"))
        #expect(SettingsSearch.keyMatches(key("Shift+Backspace"), "sh back"))
    }

    // A key with no symbol, for example a function key or a punctuation key, is its own name.
    @Test func aKeyWithNoSymbolIsItsOwnName() {
        #expect(SettingsSearch.keyMatches(key("Mod+F5"), "cmd f5"))
        #expect(SettingsSearch.keyMatches(key("Mod+["), "⌘["))
        #expect(!SettingsSearch.keyMatches(key("Mod+F5"), "cmd f6"))
    }

    @Test func noKeyAndAnEmptyQueryNeverMatch() {
        #expect(!SettingsSearch.keyMatches(.off, "cmd"))
        #expect(!SettingsSearch.keyMatches(key("Mod+N"), "  "))
        #expect(!SettingsSearch.keyMatches(key("Mod+N"), "+"))
    }
}

@Suite("the index of the sections")
struct SettingsIndexTests {
    let live = ["Live details", "Off.", "Turn on", "Remove"]
    let skills = ["Skills", "plugin", "Not installed.", "Install", "bifrost-hand-over"]

    func index(
        general: [GeneralRow] = GeneralRow.allCases, slash: [String] = ["/compact", "/clear"],
        live: [String]? = nil, skills: [String]? = nil,
        shown: Set<SettingsSection> = [.general, .slash, .keys, .live, .skills]
    ) -> [SearchSection] {
        SettingsSearch.index(
            general: general, slash: slash, keys: defaultKeyRows, live: live ?? self.live,
            skills: skills ?? self.skills, shown: shown)
    }

    @Test func theIndexHasTheShownSectionsInTheOrderOfTheTabs() {
        let sections = index()
        #expect(sections.map(\.id) == [.general, .slash, .keys, .live, .skills])
        #expect(
            sections.map(\.title) == [
                "General", "Slash commands", "Keys", "Live details", "Skills",
            ])
    }

    @Test func eachSectionHasItsRows() throws {
        let sections = index()
        try #require(sections.count == 5)
        #expect(sections[0].rows.map(\.id) == GeneralRow.allCases.map(\.rawValue))
        #expect(sections[0].rows.allSatisfy { $0.text == $0.id })
        #expect(sections[0].rows.allSatisfy { $0.key == nil })
        #expect(sections[1].rows == [
            SearchRow(id: "/compact", text: "/compact"), SearchRow(id: "/clear", text: "/clear"),
        ])
        #expect(sections[2].rows.count == 84)
        #expect(
            sections[2].rows.first { $0.id == "dictation:hold" }
                == SearchRow(id: "dictation:hold", text: "Dictation key", key: key("Space")))
        #expect(
            sections[2].rows.first { $0.id == "take-control:mod" }
                == SearchRow(
                    id: "take-control:mod", text: "Take control", key: key("Mod+Shift+T")))
        #expect(
            sections[3].rows == [SearchRow(id: "live", text: "Live details Off. Turn on Remove")])
        let skillsText = "Skills plugin Not installed. Install bifrost-hand-over"
        #expect(sections[4].rows == [SearchRow(id: "skills", text: skillsText)])
    }

    @Test func theSkillsSectionIsFoundByTheNameOfASkill() {
        #expect(SettingsSearch.search("hand-over", index())?.map(\.id) == [.skills])
    }

    // A section that shows the later text has no rows, and Live details and Skills have no rows
    // with no words. The search does not find such a section, also not by its title. Reviews
    // always has its rows.
    @Test func aSectionWithNoRowsIsNotIndexed() {
        let all = index(live: [], skills: [], shown: Set(SettingsSection.allCases))
        #expect(all.map(\.id) == [.general, .slash, .keys, .reviews])
        #expect(SettingsSearch.search("updates", all) == [])
        #expect(SettingsSearch.search("modules", all) == [])
        #expect(SettingsSearch.search("daily update", all) == [])
        #expect(SettingsSearch.search("live details", all) == [])
    }

    // The index has only the General rows that the section gives. The search does not find a
    // row that is not in the list.
    @Test func theIndexHasOnlyTheShownGeneralRows() {
        let rows = GeneralRow.allCases.filter { $0 != .introduction }
        let sections = index(general: rows)
        #expect(sections.first?.rows.map(\.id) == rows.map(\.rawValue))
        #expect(SettingsSearch.search("introduction", sections) == [])
        #expect(index(general: []).first?.id == .slash)
    }

    @Test func aSectionThatDoesNotShowIsNotIndexed() {
        #expect(index(shown: [.general, .keys]).map(\.id) == [.general, .keys])
        #expect(index(shown: []).isEmpty)
    }

    // The user can add a command there, so the section stays in the index with no command.
    @Test func anEmptySlashListIsStillFoundByItsTitle() {
        let sections = index(slash: [])
        #expect(sections.map(\.id).contains(.slash))
        #expect(
            SettingsSearch.search("slash", sections)?.first
                == SearchHit(id: .slash, title: "Slash commands", whole: true, rows: []))
    }
}

@Suite("the hits of a search")
struct SettingsSearchHitTests {
    let sections = [
        SearchSection(
            id: .general, title: "General",
            rows: [
                SearchRow(id: "Row flash", text: "Row flash"),
                SearchRow(
                    id: #"Default app for "Open project""#,
                    text: #"Default app for "Open project""#),
            ]),
        SearchSection(
            id: .slash, title: "Slash commands",
            rows: [SearchRow(id: "/compact", text: "/compact")]),
        SearchSection(
            id: .keys, title: "Keys",
            rows: [
                SearchRow(id: "open:mod", text: "Open", key: key("Mod+Enter")),
                SearchRow(id: "take-control:mod", text: "Take control", key: key("Mod+Shift+T")),
                SearchRow(id: "copy-id:key", text: "Copy session ID", key: .off),
            ]),
        SearchSection(
            id: .live, title: "Live details",
            rows: [SearchRow(id: "live", text: "Live details On. Turn off")]),
    ]

    @Test func anEmptyQueryGivesNoHitsSoTheTabsShow() {
        #expect(SettingsSearch.search("", sections) == nil)
        #expect(SettingsSearch.search("   ", sections) == nil)
    }

    @Test func theHitsAreBySectionInTheOrderOfTheTabsAndASectionWithNoMatchIsHidden() {
        #expect(
            SettingsSearch.search("open", sections) == [
                SearchHit(
                    id: .general, title: "General", whole: false,
                    rows: [#"Default app for "Open project""#]),
                SearchHit(id: .keys, title: "Keys", whole: false, rows: ["open:mod"]),
            ])
    }

    @Test func aKeyRowIsFoundByItsKeyOrByItsLabel() {
        #expect(
            SettingsSearch.search("cmd shift t", sections) == [
                SearchHit(id: .keys, title: "Keys", whole: false, rows: ["take-control:mod"])
            ])
        #expect(
            SettingsSearch.search("control take", sections)?.first?.rows == ["take-control:mod"])
    }

    @Test func aKeyRowWithNoKeyIsFoundOnlyByItsLabel() {
        #expect(SettingsSearch.search("copy session", sections)?.first?.rows == ["copy-id:key"])
        #expect(SettingsSearch.search("copy cmd", sections) == [])
    }

    @Test func aQueryThatMatchesTheTitleShowsTheWholeSection() {
        #expect(
            SettingsSearch.search("slash", sections) == [
                SearchHit(id: .slash, title: "Slash commands", whole: true, rows: ["/compact"])
            ])
        #expect(SettingsSearch.search("turn", sections)?.map(\.id) == [.live])
    }

    // Each word can match the title of the section, the label of the row or the key.
    @Test func aRowIsFoundByAMixOfTheTitleTheLabelAndTheKey() {
        #expect(
            SettingsSearch.search("keys take", sections) == [
                SearchHit(id: .keys, title: "Keys", whole: false, rows: ["take-control:mod"])
            ])
        #expect(SettingsSearch.search("general flash", sections)?.first?.rows == ["Row flash"])
        #expect(SettingsSearch.search("take cmd", sections)?.first?.rows == ["take-control:mod"])
        #expect(SettingsSearch.search("keys flash", sections) == [])
    }

    @Test func inAMixAWordOfOneCharacterMustBeAKeyName() {
        let keys = [
            SearchSection(
                id: .keys, title: "Keys",
                rows: [
                    SearchRow(
                        id: "take-control:mod", text: "Take control", key: key("Mod+Shift+T")),
                    SearchRow(
                        id: "open-project:mod", text: "Open project in the default app",
                        key: key("Mod+Shift+O")),
                ])
        ]
        #expect(SettingsSearch.search("cmd shift t", keys)?.first?.rows == ["take-control:mod"])
        #expect(SettingsSearch.search("project cmd o", keys)?.first?.rows == ["open-project:mod"])
    }

    @Test func nothingMatchesGivesAnEmptyList() {
        #expect(SettingsSearch.search("xyz", sections) == [])
    }
}

@Suite("the texts and the keys of the search field")
struct SearchFieldTests {
    // The F key of a US keyboard.
    private let fKey = KeyCode(us: "F") ?? KeyCode(.space)

    private func hit(_ rows: [String]) -> SearchHit {
        SearchHit(id: .keys, title: "Keys", whole: false, rows: rows)
    }

    @Test func theCountLineGivesTheNumberOfMatchingRows() {
        #expect(SettingsSearch.resultCountText(nil, "") == "")
        #expect(SettingsSearch.resultCountText([], "xyz") == #"No settings match "xyz"."#)
        #expect(SettingsSearch.resultCountText([hit(["a"])], "a") == "1 setting matches.")
        #expect(
            SettingsSearch.resultCountText([hit(["a", "b"]), hit(["c"])], "a")
                == "3 settings match.")
    }

    @Test func theNoMatchTextNamesTheTrimmedQuery() {
        #expect(SettingsSearch.noMatchText("  xyz ") == #"No settings match "xyz"."#)
    }

    @Test func escClearsAQueryFirstAndClosesSettingsFromAnEmptyField() {
        #expect(SettingsSearch.escape(value: "flash", composing: false) == .clear)
        #expect(SettingsSearch.escape(value: " ", composing: false) == .clear)
        #expect(SettingsSearch.escape(value: "", composing: false) == .close)
    }

    // During a composition of an input method, Esc only cancels the composition.
    @Test func aSearchDuringACompositionDoesNotClearOrClose() {
        #expect(SettingsSearch.escape(value: "flash", composing: true) == .ignore)
        #expect(SettingsSearch.escape(value: "", composing: true) == .ignore)
    }

    @Test func cmdFMovesTheFocusToTheSearchWhileSettingsHasTheFocus() {
        let cmdF = ev(.keydown, "f", Mods(meta: true))
        #expect(SettingsSearch.isSearchShortcut(cmdF, focus: .settings, settingsOnTop: false))
        #expect(
            SettingsSearch.isSearchShortcut(
                ev(.keydown, "F", Mods(meta: true)), focus: .settings, settingsOnTop: false))
        // With no focus, Settings must be the front panel.
        #expect(SettingsSearch.isSearchShortcut(cmdF, focus: .none, settingsOnTop: true))
        #expect(!SettingsSearch.isSearchShortcut(cmdF, focus: .none, settingsOnTop: false))
        #expect(!SettingsSearch.isSearchShortcut(cmdF, focus: .other, settingsOnTop: true))
    }

    // On a layout of another script, the F key types another letter. The place of the key
    // stands in, as for each Bifrost key.
    @Test func cmdFWorksOnALayoutOfAnotherScript() {
        for letter in ["а", "φ"] {
            let event = KeyEvent(keyCode: fKey, characters: letter, modifiers: .command)
            #expect(SettingsSearch.isSearchShortcut(event, focus: .settings, settingsOnTop: false))
        }
    }

    // On Dvorak, the key at the place of the QWERTY F types "u". A Latin letter is its own key.
    @Test func aLatinLetterAtThePlaceOfFIsNotTheShortcut() {
        let event = KeyEvent(keyCode: fKey, characters: "u", modifiers: .command)
        #expect(!SettingsSearch.isSearchShortcut(event, focus: .settings, settingsOnTop: false))
    }

    @Test func aKeyOfACompositionIsNotTheShortcut() {
        let event = ev(.keydown, "f", Mods(meta: true, isComposing: true))
        #expect(!SettingsSearch.isSearchShortcut(event, focus: .settings, settingsOnTop: false))
    }

    @Test func onlyCmdFWithNoOtherModifierIsTheShortcut() {
        let other = [
            ev(.keydown, "f", Mods(shift: true, meta: true)),
            ev(.keydown, "f", Mods(ctrl: true, meta: true)),
            ev(.keydown, "f", Mods(alt: true, meta: true)),
            ev(.keydown, "f"),
            ev(.keydown, "g", Mods(meta: true)),
            ev(.keyup, "f", Mods(meta: true)),
        ]
        for event in other {
            #expect(!SettingsSearch.isSearchShortcut(event, focus: .settings, settingsOnTop: true))
        }
    }
}
