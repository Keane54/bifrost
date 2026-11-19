import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing

@testable import BifrostKeyboard
@testable import BifrostSettings

// SwiftUI has a type of the same name.
private typealias Settings = BifrostSettings.Settings

// Settings > General (docs/behaviour/settings.md, "The sections"): the rows with their labels,
// controls and hints, the saves of the rows, the installed apps of the two app selects, the note
// of the login item, the display mode, and the focus when a change removes the focused field. The
// tests that show views use a window that is never ordered front. The app finder of a test reads
// a fake list of paths, never the disk.
@MainActor
@Suite("Settings > General", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct GeneralSectionTests {
    // The labels of the rows of the Electron app, in the order of its General section.
    private static let electronOrder = [
        "Labels", "Terminal app", #"Default app for "Open project""#, "Escalation time",
        "Row flash", "macOS notification", "Sound for a red box", "Start at login",
        "Account usage from Anthropic", "Poll interval", "Snap distance", "Panel transparency",
        "Animated background", "Interface scale", "Terminal font", "Display mode",
        "Introduction",
    ]

    // The paths of the installed apps of the fake finder: Finder, Zed in the home, Warp and
    // Terminal. VS Code, Ghostty and iTerm2 are not installed.
    nonisolated private static let installed: Set<String> = [
        "/System/Library/CoreServices/Finder.app", "/Users/test/Applications/Zed.app",
        "/Applications/Warp.app", "/System/Applications/Utilities/Terminal.app",
    ]

    nonisolated private static func fakeFinder(_ terminal: TerminalAppID?) -> GeneralApps {
        GeneralApps.find(
            home: URL(filePath: "/Users/test", directoryHint: .isDirectory), terminal: terminal,
            exists: { installed.contains($0) })
    }

    @Test func theRowsAreInTheElectronOrder() async throws {
        #expect(GeneralSection.rows.map(\.rawValue) == Self.electronOrder)
        let p = try await SettingsParts()
        #expect(await shownLabels(GeneralSection(model: p.model)) == Self.electronOrder)
    }

    // Each row shows its label, the one text that names it: a search for the label shows the
    // row with that label.
    @Test func eachGeneralRowHasALabel() async throws {
        let p = try await SettingsParts()
        for row in GeneralSection.rows {
            p.model.query = row.rawValue
            let labels = await shownLabels(GeneralSection(model: p.model))
            #expect(labels.contains(row.rawValue), "\(row)")
        }
        p.model.query = "flash"
        #expect(await shownLabels(GeneralSection(model: p.model)) == ["Row flash"])
    }

    // The background shifts slowly. A check row with a friendly hint turns the motion off, and
    // the search finds the row by its words.
    @Test func theAnimatedBackgroundRowHasItsHint() async throws {
        #expect(
            GeneralSection.hint(.animatedBackground)
                == "Slowly shifting colours behind the panels. Turn it off to save battery.")
        #expect(GeneralSection.checkSetting(.animatedBackground) == \Settings.animatedBackground)
        let p = try await SettingsParts()
        let section = GeneralSection(model: p.model)
        #expect(await section.setCheck(.animatedBackground, false)?.value == true)
        #expect(!p.store.settings.animatedBackground)
        for query in ["animated", "background", "Animated background"] {
            p.model.query = query
            #expect(await shownLabels(section).contains("Animated background"), "\(query)")
        }
    }

    // Each check row saves its own setting, and only that one. Account usage has its hint.
    @Test func eachCheckRowSavesItsSetting() async throws {
        let p = try await SettingsParts()
        let section = GeneralSection(model: p.model)
        let checks: [(GeneralRow, WritableKeyPath<Settings, Bool>)] = [
            (.rowFlash, \.rowFlash), (.notifications, \.notifications),
            (.redBoxSound, \.redBoxSound), (.startAtLogin, \.startAtLogin),
            (.accountUsage, \.accountUsage), (.animatedBackground, \.animatedBackground),
        ]
        #expect(GeneralSection.rows.filter { GeneralSection.checkSetting($0) != nil }.count == 6)
        for (row, setting) in checks {
            #expect(GeneralSection.checkSetting(row) == setting)
            var expected = p.store.settings
            expected[keyPath: setting].toggle()
            #expect(await section.setCheck(row, expected[keyPath: setting])?.value == true)
            #expect(p.store.settings == expected, "\(row)")
        }
        #expect(
            GeneralSection.hint(.accountUsage)
                == "Shows usage from all your devices. Bifrost reads your Claude Code login from "
                + "the Keychain. macOS may ask you to allow this.")
        #expect(GeneralSection.hint(.startAtLogin) == nil)
    }

    // The scale saves, and the panel zooms with it, as the canvas does.
    @Test func aScaleChangeZoomsThePanel() async throws {
        let p = try await SettingsParts()
        let section = GeneralSection(model: p.model)
        UITestApp.prepare()
        let before = NSHostingView(rootView: section).fittingSize
        #expect(
            CanvasMetrics.scaleChoices.map(GeneralSection.scaleText)
                == ["80%", "90%", "100%", "110%", "120%", "130%", "140%", "150%"])
        #expect(await section.choose(scale: 120).value)
        #expect(p.store.settings.interfaceScale == 120)
        let after = NSHostingView(rootView: section).fittingSize
        #expect(after.height > before.height * 1.1)
        #expect(GeneralSection.transparencyText(0) == "0% (solid)")
        #expect(GeneralSection.transparencyText(15) == "15%")
        #expect(await section.choose(transparency: 30).value)
        #expect(p.store.settings.panelTransparency == 30)
    }

    // The Poll interval row edits the setting. The registry follows the setting
    // (AppServicesTests).
    @Test func aPollChangeReachesTheRegistry() async throws {
        let p = try await SettingsParts()
        let section = GeneralSection(model: p.model)
        #expect(
            Settings.pollChoices.map(GeneralSection.pollText)
                == ["1 second", "2 seconds", "3 seconds", "5 seconds", "10 seconds"])
        #expect(await section.choose(poll: 5).value)
        #expect(p.store.settings.pollSeconds == 5)
    }

    // The space labels rename the session actions, and the key rows of Settings take the new
    // names, so the search finds a key by them.
    @Test func aLabelsChangeRenamesTheActions() async throws {
        let p = try await SettingsParts()
        let section = GeneralSection(model: p.model)
        #expect(GeneralSection.labelChoices.map(\.text) == ["Plain", "Space"])
        #expect(ActionID.open.label(p.store.settings.labels) == "Open")
        #expect(await section.choose(labels: .space).value)
        #expect(p.store.settings.labels == .space)
        #expect(ActionID.open.label(p.store.settings.labels) == "Warp to")
        let keys = p.model.index.first { $0.id == .keys }
        #expect(keys?.rows.contains { $0.text == "Warp to" } == true)
        #expect(keys?.rows.contains { $0.text == "Open" } == false)
    }

    // The Terminal app select offers Automatic, then the installed terminal apps in their order.
    // A saved app that is not installed shows with its name, and says so after the first find.
    @Test func theTerminalSelectListsTheInstalledTerminals() async throws {
        let p = try await SettingsParts()
        let section = GeneralSection(model: p.model)
        #expect(section.terminalChoices == [RowChoice(nil, GeneralSection.autoTerminal)])
        #expect(await section.choose(terminalApp: .ghostty).value)
        #expect(section.terminalChoices.last == RowChoice(.ghostty, "Ghostty"))
        p.model.links.appFinder = Self.fakeFinder
        await p.model.findApps()
        #expect(
            section.terminalChoices == [
                RowChoice(nil, GeneralSection.autoTerminal), RowChoice(.warp, "Warp"),
                RowChoice(.terminal, "Terminal"), RowChoice(.ghostty, "Ghostty (not installed)"),
            ])
        #expect(await section.choose(terminalApp: .terminal).value)
        #expect(p.store.settings.terminalApp == .terminal)
        #expect(section.terminalChoices.count == 3)
    }

    // The default app of Open project is never Finder: Finder is not a choice, even when it is
    // installed. The terminal app of the choices follows the Terminal app setting.
    @Test func theProjectAppSelectHasNoFinder() async throws {
        let p = try await SettingsParts()
        p.model.links.appFinder = Self.fakeFinder
        await p.model.findApps()
        let section = GeneralSection(model: p.model)
        #expect(p.model.apps?.projectApps.map(\.id) == [.finder, .zed, .warp])
        #expect(
            section.projectChoices == [
                RowChoice(nil, GeneralSection.autoProject), RowChoice(.zed, "Zed"),
                RowChoice(.warp, "Warp"),
            ])
        #expect(await section.choose(terminalApp: .terminal).value)
        await p.model.findApps()
        #expect(section.projectChoices.map(\.value) == [nil, .zed, .terminal])
        #expect(await section.choose(projectApp: .zed).value)
        #expect(p.store.settings.projectApp == .zed)
        #expect(section.shownProjectApp == .zed)
    }

    // The list of Open project has only the chosen terminal app. A saved default app that is an
    // installed terminal app, but not the chosen one, shows its name with no "(not installed)".
    @Test func anInstalledSavedAppShowsItsPlainName() async throws {
        let p = try await SettingsParts()
        p.model.links.appFinder = Self.fakeFinder
        let section = GeneralSection(model: p.model)
        #expect(await section.choose(terminalApp: .warp).value)
        await p.model.findApps()
        #expect(await section.choose(projectApp: .warp).value)
        #expect(section.projectChoices.last == RowChoice(.warp, "Warp"))
        #expect(await section.choose(terminalApp: .terminal).value)
        await p.model.findApps()
        #expect(p.model.apps?.projectApps.map(\.id) == [.finder, .zed, .terminal])
        #expect(
            section.projectChoices == [
                RowChoice(nil, GeneralSection.autoProject), RowChoice(.zed, "Zed"),
                RowChoice(.terminal, "Terminal"), RowChoice(.warp, "Warp"),
            ])
        #expect(await section.choose(projectApp: .vscode).value)
        #expect(section.projectChoices.last == RowChoice(.vscode, "VS Code (not installed)"))
    }

    // A file of an older app can hold Finder as the default app. The select shows Automatic for
    // it, and has no Finder choice.
    @Test func aSavedFinderShowsAsAutomatic() async throws {
        let p = try await SettingsParts()
        p.model.links.appFinder = Self.fakeFinder
        await p.model.findApps()
        let section = GeneralSection(model: p.model)
        #expect(await section.choose(projectApp: .finder).value)
        #expect(p.store.settings.projectApp == .finder)
        #expect(section.shownProjectApp == nil)
        #expect(!section.projectChoices.contains { $0.value == .finder })
        #expect(section.projectChoices.first == RowChoice(nil, GeneralSection.autoProject))
    }

    // The family field saves its trimmed text when its edit ends, and not while the user types.
    // A refused family shows its reason on the row, and the field shows the saved family again.
    @Test func aFontFamilyDraftSavesAtTheBlur() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        let family = try #require(await s.field("Terminal font family"))
        #expect(family.stringValue == "SF Mono")
        s.type("  Menlo  ", into: family)
        #expect(s.store.settings.terminalFont.family == "SF Mono")
        #expect(s.window.makeFirstResponder(nil))
        #expect(await waitUntil { s.store.settings.terminalFont.family == "Menlo" })
        // The field ends its draft in a task after the save, so the test waits with no thread.
        #expect(await waitUntil { family.stringValue == "Menlo" })
        s.type("Bad;Font", into: family)
        #expect(s.window.makeFirstResponder(nil))
        #expect(s.model.error(of: .general(.font)) == SettingsRefusal.fontFamily.message)
        #expect(s.store.settings.terminalFont.family == "Menlo")
        #expect(await waitUntil { family.stringValue == "Menlo" })
        // A family of the menu saves at once. A draft of the field saves first, so the draft
        // cannot replace the pick at a later blur.
        #expect(GeneralSection.fontFamilies == ["SF Mono", "Menlo", "Monaco", "Courier New"])
        s.type("Courier New", into: family)
        #expect(await GeneralSection(model: s.model).choose(fontFamily: "Monaco").value)
        #expect(s.store.settings.terminalFont.family == "Monaco")
        #expect(s.model.error(of: .general(.font)) == nil)
        #expect(s.window.firstResponder === s.window)
        #expect(await waitUntil { family.stringValue == "Monaco" })
        #expect(s.window.makeFirstResponder(family))
        #expect(s.window.makeFirstResponder(nil))
        await s.store.waitForWrites()
        #expect(s.store.settings.terminalFont.family == "Monaco")
    }

    // The size field and the number rows refuse a text that is not a whole number in their
    // range, with the range, before a save starts.
    @Test func aNumberOutsideItsRangeIsRefusedWithTheRange() async throws {
        var settings = Settings()
        guard case .refused(let reason) = GeneralSection.saveSize("30") else {
            Issue.record("A size of 30 saved.")
            return
        }
        #expect(reason == "Enter a whole number from 9 to 24.")
        guard case .edit(let change) = GeneralSection.saveSize("14") else {
            Issue.record("A size of 14 was refused.")
            return
        }
        change(&settings)
        #expect(settings.terminalFont.size == 14)
        guard case .refused(let escalation) = NumberRow.save("500", range: 0...120, { _, _ in })
        else {
            Issue.record("An escalation of 500 saved.")
            return
        }
        #expect(escalation == "Enter a whole number from 0 to 120.")
        guard case .refused = GeneralSection.saveFamily("   ") else {
            Issue.record("An empty family saved.")
            return
        }
    }

    // Why the last change of the login item failed shows under Start at login. A login item that
    // waits for the approval gets the button to the Login Items of System Settings.
    @Test func theLoginItemProblemShowsUnderStartAtLogin() async throws {
        let p = try await SettingsParts()
        let section = GeneralSection(model: p.model)
        UITestApp.prepare()
        let plain = NSHostingView(rootView: section).fittingSize
        #expect(section.loginItemNote == nil)
        let links = LinkValues()
        p.model.links.loginItemProblem = { links.problem }
        p.model.links.openLoginItems = { links.opened += 1 }
        links.problem = .needsApproval
        #expect(
            section.loginItemNote
                == LoginItemNote(text: LoginItemError.needsApproval.message, opensSettings: true))
        section.openLoginItems()
        #expect(links.opened == 1)
        #expect(NSHostingView(rootView: section).fittingSize.height > plain.height)
        links.problem = .failed(code: 5)
        #expect(
            section.loginItemNote
                == LoginItemNote(
                    text: LoginItemError.failed(code: 5).message, opensSettings: false))
        links.problem = nil
        #expect(section.loginItemNote == nil)
    }

    // The last line of General is the version of the app, or "Bifrost" with no version. The
    // notice of the Claude Code version (phase 4d gives its text) shows above the rows. Both
    // show only with no search.
    @Test func theVersionLineAndTheNoticeShowWithNoSearch() async throws {
        let p = try await SettingsParts()
        let section = GeneralSection(model: p.model)
        UITestApp.prepare()
        #expect(section.versionLine == "Bifrost")
        p.model.links.appVersion = "0.0.1"
        #expect(section.versionLine == "Bifrost 0.0.1")
        #expect(section.notice == nil)
        let plain = NSHostingView(rootView: section).fittingSize
        let text = "Bifrost couldn't check the Claude Code version."
        p.model.versionNotice = text
        #expect(section.notice == text)
        #expect(NSHostingView(rootView: section).fittingSize.height > plain.height)
        p.model.query = "flash"
        #expect(section.versionLine == nil)
        #expect(section.notice == nil)
        #expect(await shownLabels(section) == ["Row flash"])
    }

    // The display mode is not a setting: the row asks the window for the mode and changes no
    // setting.
    @Test func theDisplayModeRowAsksTheWindow() async throws {
        let p = try await SettingsParts()
        let section = GeneralSection(model: p.model)
        #expect(GeneralSection.displayChoices.map(\.text) == ["Window", "Borderless", "Fullscreen"])
        let links = LinkValues()
        p.model.links.requestDisplayMode = { links.modes.append($0) }
        let before = p.store.settings
        section.choose(displayMode: .fullscreen)
        #expect(links.modes == [.fullscreen])
        #expect(p.store.settings == before)
    }

    // A change that removes the field with the focus gives the focus to the search field during
    // a search, else to the panel, so it never falls to the window, where the single keys act. A
    // focus that leaves the field while the field stays needs no help. The check of the focus
    // runs in a task of the main actor, so the test waits with no thread.
    @Test func aRemovedFocusedFieldGivesTheFocusToTheSearchOrThePanel() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        let search = try #require(s.host.searchFieldView)
        var family = try #require(await s.field("Terminal font family"))
        #expect(s.window.makeFirstResponder(family))
        s.model.query = "flash"
        #expect(await waitUntil { s.editingField === search })
        s.model.query = ""
        family = try #require(await s.field("Terminal font family"))
        #expect(s.window.makeFirstResponder(family))
        s.model.showTab(.keys)
        #expect(await waitUntil { s.window.firstResponder === s.host })
        #expect(s.host.focusPlace() == .settings)
        s.model.showTab(.general)
        family = try #require(await s.field("Terminal font family"))
        #expect(s.window.makeFirstResponder(family))
        #expect(s.window.makeFirstResponder(nil))
        #expect(s.host.isCheckingFocus)
        #expect(await waitUntil { !s.host.isCheckingFocus })
        #expect(s.window.firstResponder === s.window)
    }

    // MARK: - Helpers

    // The values that the closures of the links of a test read and record: the login item and
    // the display mode.
    @MainActor
    private final class LinkValues {
        var problem: LoginItemError?
        var opened = 0
        var modes: [DisplayMode] = []
    }
}

// The labels that the rows of a view show, in their order (SettingRowLabels). The view shows in a
// window that is never ordered front, until it gives its labels.
@MainActor
func shownLabels(_ view: some View) async -> [String] {
    UITestApp.prepare()
    let seen = LabelsSeen()
    let host = NSHostingView(
        rootView: view.onPreferenceChange(SettingRowLabels.self) { labels in seen.set(labels) })
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 900), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    await render(host) { !seen.labels.isEmpty }
    return seen.labels
}

// The labels of the last preference change.
private final class LabelsSeen: Sendable {
    private let value = Mutex<[String]>([])

    var labels: [String] { value.withLock { $0 } }

    func set(_ labels: [String]) {
        value.withLock { $0 = labels }
    }
}
