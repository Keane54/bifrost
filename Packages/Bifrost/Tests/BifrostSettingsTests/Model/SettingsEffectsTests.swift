import BifrostKeyboard
import BifrostSessions
import Testing

@testable import BifrostFoundation
@testable import BifrostSettings

// The effects of a settings change (docs/behaviour/settings.md, "When a setting changes") and the
// start fix of Start at login.

private func with(_ change: (inout Settings) -> Void) -> Settings {
    var settings = Settings()
    change(&settings)
    return settings
}

// The effects of one change of the defaults.
private func effects(of change: (inout Settings) -> Void) -> [SettingsEffect] {
    SettingsEffects.effects(Settings(), with(change))
}

@Suite("the settings effects")
struct SettingsEffectsTests {
    // Each changed setting gives one effect, in a fixed order: login item, menu, zoom, account
    // usage, Reviews, Reviews view, Reviews poll, Reviews auto fix, updates.
    @Test func eachChangedSettingGivesOneEffectInTheFixedOrder() {
        let old = Settings()
        let new = with {
            $0.autoUpdate = false
            $0.reviewsAutoFix = false
            $0.reviewsPollMinutes = 5
            $0.reviewsIgnore = ["acme/*"]
            $0.reviewsWatch = true
            $0.accountUsage = true
            $0.interfaceScale = 120
            $0.keys = ["toggle-fullscreen:mod": .null]
            $0.startAtLogin = true
        }
        #expect(
            SettingsEffects.effects(old, new) == [
                .loginItem(on: true), .menu, .zoom(scale: 120), .accountUsage(on: true),
                .reviews(on: true), .reviewsView, .reviewsPoll, .reviewsAutoFix(on: false),
                .updates(on: false),
            ])
    }

    @Test func startAtLoginGivesTheLoginItemEffectBothWays() {
        let on = with { $0.startAtLogin = true }
        #expect(SettingsEffects.effects(Settings(), on) == [.loginItem(on: true)])
        #expect(SettingsEffects.effects(on, Settings()) == [.loginItem(on: false)])
    }

    @Test func accountUsageGivesItsEffectBothWays() {
        let on = with { $0.accountUsage = true }
        #expect(SettingsEffects.effects(Settings(), on) == [.accountUsage(on: true)])
        #expect(SettingsEffects.effects(on, Settings()) == [.accountUsage(on: false)])
    }

    @Test func checkForUpdatesAutomaticallyGivesTheUpdatesEffectBothWays() {
        let off = with { $0.autoUpdate = false }
        #expect(SettingsEffects.effects(Settings(), off) == [.updates(on: false)])
        #expect(SettingsEffects.effects(off, Settings()) == [.updates(on: true)])
    }

    @Test func theReviewsSettingsGiveTheReviewsEffects() {
        let watch = with { $0.reviewsWatch = true }
        #expect(SettingsEffects.effects(Settings(), watch) == [.reviews(on: true)])
        #expect(SettingsEffects.effects(watch, Settings()) == [.reviews(on: false)])
        #expect(effects { $0.reviewsIgnore = ["acme/*"] } == [.reviewsView])
        #expect(effects { $0.reviewsTeamRequests = false } == [.reviewsView])
        #expect(effects { $0.reviewsPollMinutes = 5 } == [.reviewsPoll])
        let viewAndPoll = effects {
            $0.reviewsIgnore = ["acme/*"]
            $0.reviewsPollMinutes = 10
        }
        #expect(viewAndPoll == [.reviewsView, .reviewsPoll])
        #expect(effects { $0.reviewsMaxSessions = 5 }.isEmpty)
    }

    @Test func reviewsAutoFixGivesItsEffectAfterThePoll() {
        let off = with { $0.reviewsAutoFix = false }
        #expect(SettingsEffects.effects(Settings(), off) == [.reviewsAutoFix(on: false)])
        let onAndPoll = with {
            $0.reviewsAutoFix = true
            $0.reviewsPollMinutes = 10
        }
        #expect(
            SettingsEffects.effects(off, onAndPoll) == [.reviewsPoll, .reviewsAutoFix(on: true)])
    }

    // Only the key of a menu slot (Close Panel and Fullscreen) changes the menu. A stored key that
    // is the default key, or an entry that the key rules do not read, changes no key.
    @Test func aKeyChangeGivesTheMenuEffectOnlyForAMenuSlot() {
        #expect(effects { $0.keys = ["open:mod": "Mod+K"] }.isEmpty)
        #expect(effects { $0.keys = ["close-panel:mod": "Mod+Shift+W"] } == [.menu])
        #expect(effects { $0.keys = ["toggle-fullscreen:mod": .null] } == [.menu])
        #expect(effects { $0.keys = ["close-panel:mod": "Mod+W"] }.isEmpty)
        #expect(effects { $0.keys = ["future:mod": "Mod+J"] }.isEmpty)
        // A key back to its default changes the menu again.
        let changed = with { $0.keys = ["close-panel:mod": "Mod+Shift+W"] }
        #expect(SettingsEffects.effects(changed, with { $0.keys = [:] }) == [.menu])
    }

    @Test func anInterfaceScaleChangeGivesTheZoomEffect() {
        #expect(effects { $0.interfaceScale = 80 } == [.zoom(scale: 80)])
    }

    // The registry follows the escalation time and the poll interval itself, and the window
    // applies the rest of the look at each change. So these settings give no effect.
    @Test func theOtherSettingsGiveNoEffect() {
        #expect(effects { $0.terminalApp = .warp }.isEmpty)
        let others = effects {
            $0.escalationMinutes = 0
            $0.pollSeconds = 5
            $0.animatedBackground = false
            $0.labels = .space
            $0.notifications = false
            $0.panelTransparency = 30
            $0.projectApp = .zed
            $0.redBoxSound = false
            $0.rowFlash = false
            $0.setupDone = true
            $0.slashCommands = []
            $0.snapDistance = 0
            $0.terminalApp = .ghostty
            $0.terminalFont = TerminalFont(family: "Menlo", size: 16)
        }
        #expect(others.isEmpty)
        #expect(SettingsEffects.effects(Settings(), Settings()).isEmpty)
    }

    // At the start of a release app, the real login item state wins over the file. nil: the two
    // agree, so nothing changes.
    @Test func theRealLoginStateWinsOverTheFile() {
        let off = Settings()
        let on = with { $0.startAtLogin = true }
        #expect(SettingsEffects.loginItemFix(off, realOn: true) == true)
        #expect(SettingsEffects.loginItemFix(on, realOn: false) == false)
        #expect(SettingsEffects.loginItemFix(off, realOn: false) == nil)
        #expect(SettingsEffects.loginItemFix(on, realOn: true) == nil)
    }
}
