// The timeline of the debug bench. It comes from the scripted timeline of the prototype gate
// (docs/archive/gates/integrated-prototype). Each phase records the change of each counter from
// its start to its end as one BenchSample.
//
// The plan "gate" (92 s):
//   start 10 s    the chats attach and stream; the session list shows the rows.
//   quiet 4 s     Ctrl+C in each streaming chat: the streams stop.
//   idle 12 s     measured: no output and no input; the background moves.
//   warm 6 s      Return in each streaming chat: the streams start again.
//   stream 12 s   measured: each streaming chat streams, with no input.
//   drag 12 s     measured: the drag chat moves along the benchmark path over the other frames.
//   resize 8 s    measured: the drag chat resizes at its bottom-right corner.
//   typeprep 3 s  Ctrl+C in the typing chat; its frame comes to the front and gets the focus.
//   typing 25 s   measured: 200 keys at 10 a second into the typing chat while the others stream.
// The prototype step "end" (1 s) only waited for the quit of the gate app, so the bench has no
// such step. The plan "short" has the same phases in 30 s, for one short run.
//
// Only a Debug build has this code (#if DEBUG).
#if DEBUG
import Foundation

// One phase of one run: the seconds of the phase, the display frames, the missed frames and the
// excluded seconds (the gaps that a snapshot of the counters caused), the highest footprint of
// the app and of its children together (the attach children of the chats) in bytes, and the
// instructions and the CPU seconds of the app in the phase. The start of the phase is the host
// time in seconds (CACurrentMediaTime, the clock of mach_absolute_time) and the wall time in
// seconds since 1970. run.sh --trace puts each hitch of Instruments in its phase with them.
nonisolated package struct BenchSample: Codable, Sendable, Equatable {
    package var phase: String
    package var seconds: Double
    package var frames: Int
    package var missed: Int
    package var excludedSeconds: Double
    package var appFootprint: UInt64
    package var childFootprint: UInt64
    package var appInstructions: UInt64
    package var appCPUSeconds: Double
    package var start: Double
    package var startDate: Double

    package init(
        phase: String, seconds: Double, frames: Int, missed: Int, excludedSeconds: Double,
        appFootprint: UInt64, childFootprint: UInt64, appInstructions: UInt64,
        appCPUSeconds: Double, start: Double, startDate: Double
    ) {
        self.phase = phase
        self.seconds = seconds
        self.frames = frames
        self.missed = missed
        self.excludedSeconds = excludedSeconds
        self.appFootprint = appFootprint
        self.childFootprint = childFootprint
        self.appInstructions = appInstructions
        self.appCPUSeconds = appCPUSeconds
        self.start = start
        self.startDate = startDate
    }
}

nonisolated public enum BenchPhase: String, Codable, Sendable {
    case start, quiet, idle, warm, stream, drag, resize, typeprep, typing
}

nonisolated public struct BenchPlan: Sendable, Equatable {
    package struct Step: Sendable, Equatable {
        package var phase: BenchPhase
        package var time: Duration

        package init(phase: BenchPhase, time: Duration) {
            self.phase = phase
            self.time = time
        }
    }

    package var steps: [Step]

    package init(steps: [Step]) {
        self.steps = steps
    }

    private init(_ timeline: [(BenchPhase, Int)]) {
        steps = timeline.map { Step(phase: $0.0, time: .seconds($0.1)) }
    }

    // The plan of a bench request of the test port.
    public init(_ plan: TestBench.Plan) {
        switch plan {
        case .gate: self = .gate
        case .short: self = .short
        }
    }

    package static let gate = BenchPlan([
        (.start, 10), (.quiet, 4), (.idle, 12), (.warm, 6), (.stream, 12), (.drag, 12),
        (.resize, 8), (.typeprep, 3), (.typing, 25),
    ])

    package static let short = BenchPlan([
        (.start, 3), (.quiet, 2), (.idle, 3), (.warm, 2), (.stream, 3), (.drag, 4), (.resize, 3),
        (.typeprep, 2), (.typing, 8),
    ])

    package var total: Duration { steps.reduce(.zero) { $0 + $1.time } }
}

// The benchmark path of the prototype. The drag moves the frame by up to 420 by 220 points from
// its start, and the resize moves its bottom-right corner by up to 180 by 120 points. Each
// offset is a sine wave of the time in the phase, so each display frame gets a new point.
enum BenchPath {
    struct Offset: Sendable, Equatable {
        var x: Double
        var y: Double
    }

    static func drag(at time: Double) -> Offset {
        Offset(x: 420 * sin(time * 2 * .pi / 4), y: 220 * sin(time * 2 * .pi / 3))
    }

    static func resize(at time: Double) -> Offset {
        Offset(x: 180 * sin(time * 2 * .pi / 3), y: 120 * sin(time * 2 * .pi / 2.5))
    }

    // The typing: 10 keys a second, at most 200 keys, and Ctrl+U after each 40 keys (the
    // prototype cleared the line so that it stays short).
    static let keyInterval = 0.1
    static let keyLimit = 200
    static let keysBeforeClear = 40
}
#endif
