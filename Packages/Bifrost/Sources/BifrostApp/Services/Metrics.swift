// The measurements of the debug bench. The method is the method of the prototype gate
// (docs/archive/gates/integrated-prototype):
// - the display frames of the window and the missed frames, from CADisplayLink by the gap
//   method (FrameCounter);
// - phys_footprint, the instructions and the CPU time of the app, from proc_pid_rusage;
// - the footprint of the children of the app (the attach children of the chats), by pid.
// The capture of the window (Shot), the CPU time of WindowServer and the GPU times went: they
// used private API and programs (ps, pgrep, ioreg) that the rules of the app do not allow.
//
// Only a Debug build has this code (#if DEBUG), as the test port that starts a bench run.
#if DEBUG
import Darwin

// The frame counter of the gap method. Each display frame gives its time stamp and the display
// period. A gap of n periods between two frames counts n - 1 missed frames (the gap is rounded
// to whole periods). A snapshot of the counters blocks the main thread, so the next gap comes
// from the measurement, not from the app: that gap counts no missed frame, and its time goes to
// the excluded seconds, which the frame rate leaves out.
struct FrameCounter: Sendable, Equatable {
    private(set) var frames = 0
    private(set) var missed = 0
    private(set) var excludedSeconds = 0.0
    // The last display period in seconds (CADisplayLink.duration). A period of 0 keeps it.
    private(set) var period = 1.0 / 120
    private var last: Double?
    private var leaveOut = false

    // One display frame at the time stamp, in seconds.
    mutating func tick(at timestamp: Double, period duration: Double) {
        frames += 1
        if duration > 0 { period = duration }
        defer { last = timestamp }
        guard let last else { return }
        let gap = timestamp - last
        if leaveOut {
            leaveOut = false
            excludedSeconds += gap
            return
        }
        let skipped = Int((gap / period).rounded()) - 1
        if skipped > 0 { missed += skipped }
    }

    // The next gap comes from a snapshot. Before the first frame, the first gap is the next gap.
    mutating func leaveOutNextGap() {
        leaveOut = true
    }
}

// The check of the warm-up: the median gap of the frames of the warm-up must be the display period
// of 120 Hz within 2 %. The median needs a quarter of the frames of the warm-up at least (60 gaps).
// An occluded window, a display that sleeps and a display at 60 Hz fail. A burst of output at the
// start can drop frames, and the median then still decides.
enum DisplayCheck {
    static let period = 1.0 / 120
    static let tolerance = 0.02
    static let warmUpSeconds = 2.0
    static let leastGaps = Int((0.25 * warmUpSeconds / period).rounded(.down))

    static func matches(gaps: [Double]) -> Bool {
        guard gaps.count >= leastGaps, let median = median(gaps) else { return false }
        return abs(median - period) <= tolerance * period
    }

    static func median(_ gaps: [Double]) -> Double? {
        guard !gaps.isEmpty else { return nil }
        let sorted = gaps.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

// The usage of one process: the footprint (phys_footprint) in bytes, the instructions and the
// CPU time (user and system) in seconds since its start.
struct ProcessUsage: Sendable, Equatable {
    var footprint: UInt64
    var instructions: UInt64
    var cpuSeconds: Double
}

enum ProcessMetrics {
    // The usage of the process, or nil when the process does not exist or another user owns it.
    // The footprint is ri_phys_footprint: the phys_footprint of task_info.
    static func usage(of pid: pid_t) -> ProcessUsage? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        return ProcessUsage(
            footprint: info.ri_phys_footprint, instructions: info.ri_instructions,
            cpuSeconds: seconds(ticks: ticks, numer: timebase.numer, denom: timebase.denom))
    }

    // The CPU times of proc_pid_rusage are Mach time units. The time base gives nanoseconds.
    static func seconds(ticks: UInt64, numer: UInt32, denom: UInt32) -> Double {
        guard denom > 0 else { return 0 }
        return Double(ticks) * Double(numer) / Double(denom) / 1e9
    }

    private static let timebase: mach_timebase_info_data_t = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return base
    }()
}
#endif
