import BifrostFoundation
import Foundation
import Observation

// The usage notification (docs/behaviour/usage.md, "The usage notification"). The monitor checks
// the rules each time new values come (update): new account values from the poller or a change
// of the session usage. It has no timer of its own. The shell opens the store first, then makes
// the monitor and gives it the values with follow(session:account:).
//
// The monitor takes no focus input: unlike the box alerts, the usage notification shows also
// while the window has the focus. It gives the title and the body of each notification to
// notify, and the shell gives them to the notifier.
@MainActor
package final class UsageAlertMonitor {
    private let store: UsageAlertStore
    private let home: URL
    private let enabled: @MainActor () -> Bool
    private let notify: @MainActor (String, String) -> Void
    private let now: () -> Date
    private let zone: TimeZone
    private let readFlag: @Sendable (URL) async -> Bool

    private var account: AccountUsage?
    private var session: UsageSnapshot?
    // The last flag that the account values gave. A nil value or a value with no flag does not
    // clear it. Thus stale account values, for example after a 429 or a network error, keep a
    // known "on" flag.
    private var lastAccountFlag: Bool?
    // The task that follows the values (follow(session:account:)).
    private var following: Task<Void, Never>?

    // The task of the last notification that waits for the read of the flag. It ends after each
    // earlier such task, so a test that waits for it waits for every read.
    package private(set) var flagRead: Task<Void, Never>?
    // The save of the last change of the periods. A test waits for it.
    package private(set) var save: Task<Void, Never>?

    // enabled is true when the setting notifications is on. now gives the wall time of a check.
    // The texts use the zone. The default zone follows each change of the zone of the Mac, so
    // each text uses the zone of its show. readFlag reads the extra usage flag of ~/.claude.json
    // in the home, and a test can give a fake.
    package init(
        store: UsageAlertStore, home: URL, enabled: @escaping @MainActor () -> Bool,
        notify: @escaping @MainActor (String, String) -> Void, now: @escaping () -> Date,
        zone: TimeZone = .autoupdatingCurrent,
        readFlag: @escaping @Sendable (URL) async -> Bool = { home in
            await ClaudeJSON.extraUsageFlag(home: home)
        }
    ) {
        self.store = store
        self.home = home
        self.enabled = enabled
        self.notify = notify
        self.now = now
        self.zone = zone
        self.readFlag = readFlag
    }

    isolated deinit {
        following?.cancel()
    }

    // The values of now: the session usage of the usage lines and the account values of the
    // poller, each or nil. The monitor checks the rules at once. follow(session:account:) gives
    // each change of the values here.
    package func update(session: UsageSnapshot?, account: AccountUsage?) {
        self.session = session
        take(account)
        check()
    }

    // Follow the session usage of the registry and the account values of the poller: the values
    // of now, then the values after each change (update). A second call replaces the first.
    // stop() ends it.
    package func follow(
        session: @escaping @MainActor @Sendable () -> UsageSnapshot?,
        account: @escaping @MainActor @Sendable () -> AccountUsage?
    ) {
        following?.cancel()
        let changes = Observations { (session(), account()) }
        following = Task { [weak self] in
            for await (snapshot, values) in changes {
                guard !Task.isCancelled, let self else { return }
                self.update(session: snapshot, account: values)
            }
        }
    }

    // Stop the follow of the values and the notifications that wait for the read of the flag. A
    // save of the periods that runs goes on, so a quit can wait for it.
    package func stop() {
        following?.cancel()
        following = nil
        flagRead?.cancel()
    }

    private func take(_ value: AccountUsage?) {
        account = value
        if let flag = value?.extraUsage { lastAccountFlag = flag }
    }

    private func check() {
        let now = self.now().millisecondsSince1970
        // The same choice as the Usage HUD: fresh account values, else the session values.
        guard let source = UsageSource.pick(session, now: now, account) else { return }
        let kept = store.periods
        // The kept periods follow a later reset time in the same period, also with the setting
        // off. With the setting off, the period stays open, so a notification can show after the
        // user turns the setting on, at the next new value in the same period.
        let followed = UsageAlertRules.follow(source.limits, kept, now: now)
        let due = enabled() ? UsageAlertRules.due(source.limits, followed, now: now) : []
        // Keep the periods before the read of the flag, so a new value during the read does not
        // notify again. Write only a changed value.
        let next = UsageAlertRules.after(followed, due)
        if next != kept { save = store.set(next) }
        guard !due.isEmpty else { return }
        if let known = knownFlag(source) {
            show(due, extraUsage: known, now: now)
            return
        }
        // The reads can overlap. The texts show in the order of the checks. A cancel of the last
        // task cancels each earlier one at once, also during its read, so a stop shows no text.
        let earlier = flagRead
        flagRead = Task { [weak self, readFlag, home] in
            await withTaskCancellationHandler {
                let on = await readFlag(home)
                await earlier?.value
                guard !Task.isCancelled else { return }
                self?.show(due, extraUsage: on, now: now)
            } onCancel: {
                earlier?.cancel()
            }
        }
    }

    // The flag of fresh account values when they give one. Else a known "on" flag of older
    // account values. nil: the flag comes from the file, and a failed read of the file counts as
    // off.
    private func knownFlag(_ source: UsageSource) -> Bool? {
        let fresh: Bool? = if case .account(let values) = source { values.extraUsage } else { nil }
        return fresh ?? (lastAccountFlag == true ? true : nil)
    }

    private func show(_ alerts: [UsageAlert], extraUsage: Bool, now: Int) {
        for alert in alerts {
            let text = UsageAlertRules.text(alert, extraUsage: extraUsage, now: now, zone: zone)
            notify(text.title, text.body)
        }
    }
}
