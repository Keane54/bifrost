import BifrostFoundation
import BifrostSessions
import Foundation
import Observation

// What the Daily update panel shows: the status of the day, the tabs with their items, drafts and
// markers, the failure, and the time of the last refresh. The panel reads only this value, and it
// makes the texts.
package struct DailySnapshot: Sendable, Equatable {
    // One area that is on.
    package struct Tab: Sendable, Equatable, Identifiable {
        package var id: String
        package var name: String
        // The channel name that the user typed for the area.
        package var channel: String
        // True when a run gave the area a draft. Until then the tab has no items and no draft.
        package var hasDraft: Bool
        package var items: [DailyItem]
        package var moved: Bool
        package var draft: String
        // True when the user changed the draft.
        package var edited: Bool
        // A newer draft that waits beside the draft of the user.
        package var pending: String?
        // The time of the send of today, or nil when the area is not sent.
        package var sentAt: Date?
        // The start of the run that made the items.
        package var since: Date?
    }

    package var status: DailyStatus
    // True on a due day with an area on.
    package var due: Bool
    package var deadline: ClockTime
    package var tabs: [Tab]
    // The items that no area claimed.
    package var unplaced: [DailyItem]
    package var isRunning: Bool
    package var skipped: Bool
    // The failure of the last run, or nil when the last run was good or no run failed.
    package var failure: DailyFailure?
    // The end of the last good run, or nil.
    package var lastRefresh: Date?

    package static let idle = DailySnapshot(
        status: .noDrafts, due: false, deadline: DailySettings.defaults.deadline, tabs: [],
        unplaced: [], isRunning: false, skipped: false, failure: nil, lastRefresh: nil)

    // True while the tab shows its marker: a due day that the user did not skip, and the area is
    // not sent.
    package func showsMarker(_ tab: Tab) -> Bool {
        due && !skipped && tab.sentAt == nil
    }
}

// The state of the day, in the order of the rule that decides it: a run goes, no area is on, the
// user skipped the day, each area is sent, the last run was good, the last run failed, or no
// draft yet.
package enum DailyStatus: String, Sendable, Equatable {
    case writing, noArea, skipped, allSent, ready, failed, noDrafts
}

// The failure of the last run: its code, the detail of the state file and the name of the ticket
// source of the settings.
package struct DailyFailure: Sendable, Equatable {
    package var code: FailureCode
    package var detail: String?
    package var server: String?

    package init(code: FailureCode, detail: String? = nil, server: String? = nil) {
        self.code = code
        self.detail = detail
        self.server = server
    }

    // The text for the panel.
    package var text: String { code.text(detail: detail, server: server) }
}

// The Daily update (docs/behaviour/daily-update.md, "The schedule"): it plans the next reminder,
// runs the drafts and changes the state of the store.
// - The schedule is the next date, not a tick. One timer waits for the date
//   (DailySchedule.nextWake). The owner calls timeChanged() after a wake, a change of the clock
//   or of the time zone, and a new day, and the service plans again. settingsChanged() plans
//   again too.
// - The service marks a reminder as shown before it runs the drafts, so a wake or a second plan
//   never gives the same reminder twice. The first and the second reminder never come together
//   (DailySchedule.action). One run goes at a time. The runs that the schedule starts wait in
//   one queue, in the order of their start.
// - The store is the one place of the state. Each change goes to the store at once, and the save
//   task of the store writes the newest state. A run keeps the draft that the user changed
//   (DailyState.apply).
// - A stop is final: it ends the timer, the queue and the run that goes, and a stopped run
//   changes nothing. The app stops the service only at the quit.
@MainActor
@Observable
package final class DailyUpdateService {
    // The panel runs the drafts when it opens, only when the last run ended longer ago than this.
    package static let openGuard = Duration.seconds(300)

    static let readyText = "Your daily update is ready to check."
    static let secondText = "10 minutes left to post your daily update."
    static let failedText =
        "Bifrost couldn't write your daily update. You can still write it yourself."
    // Why there is no service when the app found no claude. The panel and Settings show it.
    package static let noClaudeText =
        "Bifrost couldn't find Claude Code, so it can't write your daily update."

    // The life of the service.
    private enum Life {
        case new, started, stopped
    }

    // What the queue does next.
    private enum Step {
        case run(Reminder)
        case notifySecond
    }

    // What a run gave.
    private enum Outcome {
        case done
        case failed
        // A run of the user found a run that goes, or the run ended with no result (a stop).
        case skipped
    }

    package private(set) var snapshot = DailySnapshot.idle
    // True while the button of the side bar shows its marker.
    package private(set) var showsMarker = false

    @ObservationIgnored private let store: DailyStateStore
    @ObservationIgnored private let runner: DailyRunner
    @ObservationIgnored private let settings: () -> DailySettings?
    @ObservationIgnored private let notifier: any Notifier
    @ObservationIgnored private let bounceDock: @MainActor () -> Void
    @ObservationIgnored private let openPanel: @MainActor (_ area: String?) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let currentCalendar: () -> Calendar
    @ObservationIgnored private let refused: @MainActor () -> Void
    @ObservationIgnored private let timer: TimerSlot
    @ObservationIgnored private var life = Life.new
    // The run that goes, from the schedule or from the user. One at a time. A step of the
    // schedule that finds a run going waits for it and uses its result.
    @ObservationIgnored private var running: Task<Outcome, Never>?
    @ObservationIgnored private var queue: [Step] = []
    @ObservationIgnored private var drain: Task<Void, Never>?
    // The task of the last run of the user (Refresh, Redo, the open of the panel). A test waits
    // for it.
    @ObservationIgnored package private(set) var manual: Task<Void, Never>?

    // settings gives the settings of now (nil for no block: the defaults count). now gives the
    // wall time. calendar gives the calendar of now, with the days and the time zone: the app
    // gives the calendar of the system, which follows a change of the time zone. A test pins
    // both and can change the time zone.
    package init(
        store: DailyStateStore, runner: DailyRunner, settings: @escaping () -> DailySettings?,
        notifier: any Notifier, bounceDock: @escaping @MainActor () -> Void,
        openPanel: @escaping @MainActor (_ area: String?) -> Void, clock: any Clock<Duration>,
        now: @escaping () -> Date, calendar: @escaping () -> Calendar,
        refused: @escaping @MainActor () -> Void = {}
    ) {
        self.refused = refused
        self.store = store
        self.runner = runner
        self.settings = settings
        self.notifier = notifier
        self.bounceDock = bounceDock
        self.openPanel = openPanel
        self.now = now
        currentCalendar = calendar
        timer = TimerSlot(clock: clock)
        refreshSnapshot()
    }

    // MARK: - The schedule

    // Plan the next reminder. A start after the draft time of a due day runs at once. Only the
    // first start counts, and a stopped service never starts again.
    package func start() {
        guard life == .new else { return }
        life = .started
        plan()
    }

    // End the timer, the queue and each run. The state of the day stays as it is.
    package func stop() {
        life = .stopped
        timer.stop()
        queue = []
        drain?.cancel()
        drain = nil
        manual?.cancel()
        manual = nil
        running?.cancel()
    }

    // A wake, a change of the clock or of the time zone, or a new day.
    package func timeChanged() { plan() }

    package func settingsChanged() { plan() }

    // The end of the saves of the store. After a stop, the owner waits for it before it closes
    // the store.
    package func savesEnded() async {
        await store.saved()
    }

    // The end of the queue, the run of the user and the saves. A test waits for it.
    package func settled() async {
        await drain?.value
        await manual?.value
        await store.saved()
    }

    private var isRunning: Bool { running != nil }

    private var state: DailyState { store.state }

    private var calendar: Calendar { currentCalendar() }

    // Plan again: roll the day, decide the action of now, then wait for the next date. The mark
    // of the reminder is set and saved before the run, so no second plan gives it again.
    private func plan() {
        guard life == .started else { return }
        let current = now()
        let config = settings() ?? .defaults
        var next = state
        next.rollDay(to: DayMarks.dateText(current, calendar: calendar))
        let action = DailySchedule.action(now: current, config, next.marks, calendar: calendar)
        let step: Step?
        switch action {
        case .none:
            step = nil
        case .run(let reminder):
            if reminder == .second { next.setSecondShown() } else { next.setFirstShown() }
            step = .run(reminder)
        case .notifySecond:
            // A step of the schedule goes: its reminder is the only one. The second never shows
            // right after the first.
            next.setSecondShown()
            step = drain == nil ? .notifySecond : nil
        }
        update(next)
        arm(after: current, config)
        refreshSnapshot()
        if let step { enqueue(step) }
    }

    // One timer for the next date. It replaces the timer that waits.
    private func arm(after current: Date, _ config: DailySettings) {
        guard let wake = DailySchedule.nextWake(
            after: current, config, state.marks, calendar: calendar)
        else {
            timer.stop()
            return
        }
        let wait = Duration.seconds(max(0, wake.timeIntervalSince(current)))
        timer.start(after: wait) { [weak self] in self?.plan() }
    }

    private func enqueue(_ step: Step) {
        queue.append(step)
        guard drain == nil else { return }
        drain = Task { await self.work() }
    }

    // Work the queue until it is empty. A stop cancels the task and empties the queue.
    private func work() async {
        while life == .started, !Task.isCancelled, !queue.isEmpty {
            await perform(queue.removeFirst())
        }
        if !Task.isCancelled { drain = nil }
    }

    private func perform(_ step: Step) async {
        switch step {
        case .notifySecond:
            notify(Self.secondText, bounce: true, sound: true)
        case .run(let reminder):
            let outcome = await runDrafts(waits: true)
            guard life == .started, !Task.isCancelled else { return }
            let second = reminder == .second
            // After the deadline, a late start makes no sound, also for a failure.
            let sound = reminder != .late
            if outcome == .failed {
                notify(Self.failedText, bounce: second, sound: sound)
            } else {
                notify(second ? Self.secondText : Self.readyText, bounce: second, sound: sound)
            }
        }
    }

    // Show the reminder, unless the work of today is done: a Mark as sent or a Skip today during
    // the run ends the reminder.
    private func notify(_ text: String, bounce: Bool, sound: Bool) {
        let config = settings() ?? .defaults
        guard !todayMarks().allDone(config.areas) else { return }
        let note = AlertNote(title: "Daily update", body: text, source: .dailyUpdate, sound: sound)
        notifier.show(
            note, onClick: { [weak self] _ in self?.openFirstUnsent() },
            onFailed: { [weak self] in self?.refused() })
        if bounce { bounceDock() }
    }

    // The marks of today: the marks of an earlier day count as fresh marks.
    private func todayMarks() -> DayMarks {
        let date = DayMarks.dateText(now(), calendar: calendar)
        return state.marks.date == date ? state.marks : .fresh(date)
    }

    // A click on a reminder opens the panel at the first area that is not sent.
    private func openFirstUnsent() {
        let config = settings() ?? .defaults
        let marks = todayMarks()
        let area = config.areas.first { $0.on && marks.sent[$0.id] == nil }
        openPanel(area?.id)
    }

    // MARK: - The runs

    // The panel opened. It runs the drafts only when no run goes and the last run ended more than
    // the guard ago.
    package func panelOpened() {
        guard !isRunning else { return }
        // A gap below zero (the clock went back) runs.
        if let last = state.lastRun?.at,
            (0...Self.guardSeconds).contains(now().timeIntervalSince(last))
        {
            return
        }
        manualRun(area: nil)
    }

    // Refresh and Redo always run, unless a run goes.
    package func refresh() { manualRun(area: nil) }

    package func redo(_ area: String) { manualRun(area: area) }

    private static var guardSeconds: Double {
        Double(openGuard.components.seconds)
    }

    // A run with no area on, or a Redo of an area that is off, does nothing.
    private func manualRun(area: String?) {
        let areas = (settings() ?? .defaults).areas
        guard life == .started, !isRunning,
            areas.contains(where: { $0.on && (area == nil || $0.id == area) })
        else { return }
        manual = Task {
            _ = await self.runDrafts(only: area)
            if !Task.isCancelled { self.manual = nil }
        }
    }

    // Run the drafts for all areas, or for one area (Redo), and keep the result in the state. A
    // run that goes already: the step of the schedule waits for it and gives its result, a run
    // of the user does nothing. A stopped run changes nothing.
    private func runDrafts(only area: String? = nil, waits: Bool = false) async -> Outcome {
        if let going = running { return waits ? await going.value : .skipped }
        let task = Task { await self.execute(only: area) }
        running = task
        refreshSnapshot()
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        running = nil
        refreshSnapshot()
        return outcome
    }

    private func execute(only area: String?) async -> Outcome {
        var config = settings() ?? .defaults
        if let area {
            config.areas = config.areas.map { item in
                var item = item
                item.on = item.on && item.id == area
                return item
            }
        }
        do throws(RunFailure) {
            let result = try await runner.run(config, state: state, now: now())
            guard life == .started, !Task.isCancelled else { return .skipped }
            var next = state
            let end = now()
            if let area {
                if let one = result.areas.first(where: { $0.id == area }) {
                    next.redo(one, since: result.since[area])
                    next.lastRun = DailyRun(at: end, ok: true)
                }
            } else {
                next.apply(
                    run: result.areas, unplaced: result.unplaced, at: end, since: result.since)
            }
            update(next)
            return .done
        } catch {
            guard life == .started, !Task.isCancelled, let code = error.code else {
                return .skipped
            }
            var next = state
            next.failRun(at: now(), code, detail: error.detail)
            update(next)
            return .failed
        }
    }

    // MARK: - The edits of the user

    package func edit(_ area: String, _ text: String) {
        change { $0.editDraft(area, text: text) }
    }

    package func usePending(_ area: String) { change { $0.usePending(area) } }

    package func keepMine(_ area: String) { change { $0.keepMine(area) } }

    // A second Mark as sent, or an Undo with no mark of today, changes nothing, so a double click
    // never moves the start of the next draft.
    package func markSent(_ area: String) {
        let time = now()
        change { if $0.marks.sent[area] == nil { $0.markSent(area, at: time) } }
    }

    package func undoSent(_ area: String) {
        change { if $0.marks.sent[area] != nil { $0.undoSent(area) } }
    }

    package func skipToday() { change { $0.setSkipped(true) } }

    // The Undo of Skip today. The next date of the schedule acts on it, so it gives no reminder at
    // once.
    package func undoSkip() { change { $0.setSkipped(false) } }

    // The draft of an area as standard Markdown, with each bold part as **text**.
    package func copyText(_ area: String) -> String {
        let draft = state.areas[area]?.draft ?? ""
        return DailyMarkup.markdown(DailyMarkup.attributed(draft))
    }

    // MARK: - The state

    private func change(_ edit: (inout DailyState) -> Void) {
        var next = state
        next.rollDay(to: DayMarks.dateText(now(), calendar: calendar))
        edit(&next)
        update(next)
    }

    // Give the new state to the store, which keeps it and saves it, and show it.
    private func update(_ next: DailyState) {
        guard next != state else { return }
        store.keep(next)
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        let config = settings() ?? .defaults
        let current = now()
        let marks = state.marks
        let tabs = config.areas.filter(\.on).map { area in
            let view = state.areas[area.id]
            return DailySnapshot.Tab(
                id: area.id, name: area.name, channel: area.channel, hasDraft: view != nil,
                items: view?.items ?? [], moved: view?.moved ?? false, draft: view?.draft ?? "",
                edited: view?.edited ?? false, pending: view?.pending, sentAt: marks.sent[area.id],
                since: view?.since)
        }
        let run = state.lastRun
        var failure: DailyFailure?
        if let run, !run.ok, let code = run.failure {
            failure = DailyFailure(code: code, detail: run.detail, server: config.source.server)
        }
        let status: DailyStatus
        if isRunning {
            status = .writing
        } else if tabs.isEmpty {
            status = .noArea
        } else if marks.skipped {
            status = .skipped
        } else if tabs.allSatisfy({ $0.sentAt != nil }) {
            status = .allSent
        } else if run?.ok == true {
            status = .ready
        } else if failure != nil {
            status = .failed
        } else {
            status = .noDrafts
        }
        let due =
            config.days.contains(DailySchedule.dayNumber(current, calendar: calendar))
            && !tabs.isEmpty
        snapshot = DailySnapshot(
            status: status, due: due, deadline: config.deadline, tabs: tabs,
            unplaced: state.unplaced, isRunning: isRunning, skipped: marks.skipped,
            failure: failure, lastRefresh: run?.ok == true ? run?.at : nil)
        showsMarker = DailySchedule.showsMarker(
            now: current, config, marks, calendar: calendar)
    }
}
