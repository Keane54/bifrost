import BifrostFoundation
import Foundation

// The checks of the Performance monitor (docs/behaviour/health.md, "Performance"): the reasons
// for a Warning or a Problem, and the level of Bifrost's health.

package enum HealthLevel: Sendable, Comparable {
    case ok, warning, problem
}

package struct HealthReason: Sendable, Equatable {
    package var level: HealthLevel
    package var text: String
    // True for a reason from a past event (a failed poll, save or Live details start). Clear
    // removes it. A live measurement shows again at the next check while it is still true.
    package var past: Bool

    package init(level: HealthLevel, text: String, past: Bool = false) {
        self.level = level
        self.text = text
        self.past = past
    }
}

// What the checks read at one time.
package struct HealthInput: Sendable {
    // The time on the timeline of the monitor.
    package var now: Duration
    // The wall time, for the times in the texts.
    package var wall: Date
    package var history: SampleHistory
    // The frame rates of the bursts of the current count, the newest last.
    package var frameRates: [Double]
    // The longest pass of the main run loop in the last full 60 s window, or nil.
    package var mainThreadDelay: Duration?
    package var events: PastEvents
    // False while the Mac is offline.
    package var online: Bool
    // The terminal processes with no chat window for more than 60 s.
    package var orphans: Int

    package init(
        now: Duration, wall: Date, history: SampleHistory = SampleHistory(),
        frameRates: [Double] = [], mainThreadDelay: Duration? = nil,
        events: PastEvents = PastEvents(), online: Bool = true, orphans: Int = 0
    ) {
        self.now = now
        self.wall = wall
        self.history = history
        self.frameRates = frameRates
        self.mainThreadDelay = mainThreadDelay
        self.events = events
        self.online = online
        self.orphans = orphans
    }

    // The newest sample, when it is not older than 60 s. An older sample is no data: for example
    // the reads failed, or the Mac slept.
    package var freshSample: Sample? {
        guard let newest = history.newest, now - newest.at <= HealthChecks.freshFor else {
            return nil
        }
        return newest
    }

    package var hasFreshSample: Bool { freshSample != nil }
}

package enum HealthChecks {
    // A sample is data for this time.
    package static let freshFor = Duration.seconds(60)
    // The memory of the app, the chat terminals not included.
    package static let memoryWarning: UInt64 = 1 << 30
    package static let memoryProblem: UInt64 = 1536 << 20
    // One chat terminal, in whole MB.
    package static let terminalWarning = 500
    // The growth of the memory of the app in MB an hour.
    package static let growthWarning = 300
    package static let growthProblem = 800
    // The CPU of the app in percent of one core, the average of 2 minutes.
    package static let cpuWarning = 50
    package static let cpuProblem = 100
    // The frame rate of two bursts in a row.
    package static let lowFrameRate = 30.0
    // The longest pass of the main run loop in 60 s, in ms.
    package static let delayWarning = 200
    package static let delayProblem = 1000
    // The failures in a row of a poll.
    package static let streakWarning = 3
    package static let streakProblem = 10

    // The reasons, the problems first, then the warnings, each in the order of the checks. A
    // check with no data gives no reason: the checks of the samples need a fresh sample. The
    // terminal, the growth, the CPU and the delay go to whole numbers first, so a reason always
    // shows a value above its limit.
    package static func reasons(_ input: HealthInput, zone: TimeZone = .current) -> [HealthReason]
    {
        var found: [HealthReason] = []
        if let sample = input.freshSample {
            found += memory(sample.use)
            found += growth(input)
            found += cpu(input)
        }
        if input.frameRates.count >= 2,
            input.frameRates.suffix(2).allSatisfy({ $0 < lowFrameRate })
        {
            found.append(HealthReason(level: .warning, text: HealthText.lowFrameRate))
        }
        if let delay = input.mainThreadDelay {
            let ms = Int((delay / .milliseconds(1)).rounded())
            if let level = level(ms, warning: delayWarning, problem: delayProblem) {
                found.append(HealthReason(level: level, text: HealthText.slow(ms: ms)))
            }
        }
        found += past(input)
        if input.orphans > 0 {
            found.append(HealthReason(level: .warning, text: HealthText.orphans(input.orphans)))
        }
        found += saves(input, zone: zone)
        return found.filter { $0.level == .problem } + found.filter { $0.level != .problem }
    }

    // The level of Bifrost's health: the worst reason. With no reason, OK needs a measured sample,
    // so nil (the panel says that Bifrost is checking) while the monitor has no data.
    package static func level(of reasons: [HealthReason], measured: Bool) -> HealthLevel? {
        if let worst = reasons.map(\.level).max() { return worst }
        return measured ? .ok : nil
    }

    private static func memory(_ use: BifrostUse) -> [HealthReason] {
        var found: [HealthReason] = []
        let app = use.app.memory
        if app > memoryProblem {
            let text = HealthText.ownMemory(app, limit: memoryProblem)
            found.append(HealthReason(level: .problem, text: text))
        } else if app > memoryWarning {
            let text = HealthText.ownMemory(app, limit: memoryWarning)
            found.append(HealthReason(level: .warning, text: text))
        }
        let terminal = HealthText.wholeMegabytes(use.largestTerminal)
        if terminal > terminalWarning {
            let text = HealthText.terminalMemory(megabytes: terminal, limit: terminalWarning)
            found.append(HealthReason(level: .warning, text: text))
        }
        return found
    }

    private static func growth(_ input: HealthInput) -> [HealthReason] {
        guard let perHour = input.history.growth(at: input.now) else { return [] }
        let megabytes = Int((perHour / 1_048_576).rounded())
        guard let level = level(megabytes, warning: growthWarning, problem: growthProblem) else {
            return []
        }
        return [HealthReason(level: level, text: HealthText.growth(megabytesAnHour: megabytes))]
    }

    private static func cpu(_ input: HealthInput) -> [HealthReason] {
        guard let average = input.history.averageCPU(at: input.now) else { return [] }
        let percent = Int(average.rounded())
        guard let level = level(percent, warning: cpuWarning, problem: cpuProblem) else {
            return []
        }
        return [HealthReason(level: level, text: HealthText.cpu(percent: percent))]
    }

    // The polls that keep failing and a failed start of Live details. While offline, a network
    // part gives no reason.
    private static func past(_ input: HealthInput) -> [HealthReason] {
        var found: [HealthReason] = []
        for part in PollPart.allCases where input.online || !part.usesNetwork {
            let count = input.events.streaks[part]
            let level: HealthLevel? =
                count >= streakProblem ? .problem : count >= streakWarning ? .warning : nil
            guard let level else { continue }
            found.append(
                HealthReason(level: level, text: HealthText.poll(part, count: count), past: true))
        }
        if input.events.liveStart != nil {
            found.append(HealthReason(level: .warning, text: HealthText.liveStart, past: true))
        }
        return found
    }

    // The failed saves of the last hour.
    private static func saves(_ input: HealthInput, zone: TimeZone) -> [HealthReason] {
        input.events.saves.compactMap { save in
            guard input.now - save.time.at < PastEvents.saveSpan else { return nil }
            let text = HealthText.saveFailed(save.what, at: save.time.wall, zone: zone)
            return HealthReason(level: .warning, text: text, past: true)
        }
    }

    // The level of a value above a limit: a problem above the problem limit, a warning above the
    // warning limit, else nil.
    private static func level(_ value: Int, warning: Int, problem: Int) -> HealthLevel? {
        if value > problem { return .problem }
        if value > warning { return .warning }
        return nil
    }
}
