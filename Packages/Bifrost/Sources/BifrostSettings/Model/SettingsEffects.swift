import BifrostKeyboard

// The effects of a settings change (docs/behaviour/settings.md, "When a setting changes"): the
// work that a change starts outside the settings file. The registry follows the escalation time
// and the poll interval itself, and the window applies the rest of the look at each change, so
// these settings give no effect here. A change of the terminal app needs no effect: the app finds
// the installed apps at each use and keeps no cache.
public enum SettingsEffect: Sendable, Equatable {
    // Start at login: register or remove the login item.
    case loginItem(on: Bool)
    // The key of a menu slot changed: build the menu again.
    case menu
    // The Interface scale in percent.
    case zoom(scale: Int)
    // Start or stop the poll of the account usage.
    case accountUsage(on: Bool)
    // Check for updates automatically.
    case updates(on: Bool)
    // Watch the code host for review requests: start or stop the watcher.
    case reviews(on: Bool)
    // Show team requests or the ignore list changed: build the Reviews rows again.
    case reviewsView
    // The Reviews poll interval changed: plan the next poll again.
    case reviewsPoll
    // Fix the review comments without a request.
    case reviewsAutoFix(on: Bool)
}

package enum SettingsEffects {
    // The effects of a change from old to new, in this order: login item, menu, zoom, account
    // usage, Reviews, Reviews view, Reviews poll, Reviews auto fix, updates. Each changed setting
    // gives one effect. Equal settings give none.
    package static func effects(_ old: Settings, _ new: Settings) -> [SettingsEffect] {
        var effects: [SettingsEffect] = []
        if old.startAtLogin != new.startAtLogin {
            effects.append(.loginItem(on: new.startAtLogin))
        }
        if menuKeysChanged(old, new) { effects.append(.menu) }
        if old.interfaceScale != new.interfaceScale {
            effects.append(.zoom(scale: new.interfaceScale))
        }
        if old.accountUsage != new.accountUsage {
            effects.append(.accountUsage(on: new.accountUsage))
        }
        if old.reviewsWatch != new.reviewsWatch { effects.append(.reviews(on: new.reviewsWatch)) }
        if old.reviewsTeamRequests != new.reviewsTeamRequests
            || old.reviewsIgnore != new.reviewsIgnore
        {
            effects.append(.reviewsView)
        }
        if old.reviewsPollMinutes != new.reviewsPollMinutes { effects.append(.reviewsPoll) }
        if old.reviewsAutoFix != new.reviewsAutoFix {
            effects.append(.reviewsAutoFix(on: new.reviewsAutoFix))
        }
        if old.autoUpdate != new.autoUpdate { effects.append(.updates(on: new.autoUpdate)) }
        return effects
    }

    // The value of Start at login that the start of a release app saves: the real state of the
    // login item. The user can change the login item in System Settings while Bifrost does not
    // run, so the real state wins over the file. nil: the two agree, and nothing changes.
    package static func loginItemFix(_ settings: Settings, realOn: Bool) -> Bool? {
        settings.startAtLogin == realOn ? nil : realOn
    }

    // True when the key of a menu slot changed. The key map reads the stored keys with the key
    // rules, so a stored default key or an entry that the rules do not read changes no key.
    private static func menuKeysChanged(_ old: Settings, _ new: Settings) -> Bool {
        guard old.keys != new.keys else { return false }
        let before = KeyMap(stored: old.keys)
        let after = KeyMap(stored: new.keys)
        return KeySlot.all.contains { $0.isMenu && before[$0] != after[$0] }
    }
}
