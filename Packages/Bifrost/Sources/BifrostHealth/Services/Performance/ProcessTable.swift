import Darwin

// Gives one read of the process table. The app uses ProcessTable. A test gives a fake.
package protocol ProcessSampling: Sendable {
    // The processes of the user at the time of the read. A process that ends during the read can
    // be missing.
    func read() async -> [ProcessSample]
}

// One read of the process table with the process APIs of macOS (libproc). It starts no program
// (user decision, 2026-11-16). The read lists all pids, and keeps the processes of the user of
// the app: the app can read the footprint and the CPU time only of these processes, and the app,
// its chat terminals and the Claude sessions are all processes of the user.
package struct ProcessTable: ProcessSampling {
    package init() {}

    // The read runs off the actor of the caller. No call waits for a process.
    @concurrent package func read() async -> [ProcessSample] {
        Self.readNow()
    }

    // For each pid of proc_listallpids: proc_pidinfo with PROC_PIDT_SHORTBSDINFO gives the parent
    // and the user, and proc_pid_rusage gives the footprint (ri_phys_footprint) and the CPU time
    // (ri_user_time and ri_system_time, in units of the Mach time base).
    static func readNow() -> [ProcessSample] {
        let user = getuid()
        var table: [ProcessSample] = []
        for pid in allPIDs() where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size,
                info.pbsi_uid == user, let usage = usage(of: pid)
            else { continue }
            table.append(
                ProcessSample(
                    pid: pid, parent: pid_t(bitPattern: info.pbsi_ppid),
                    footprint: usage.ri_phys_footprint,
                    cpuTime: cpuTime(ticks: usage.ri_user_time &+ usage.ri_system_time)))
        }
        return table
    }

    // Each pid of the system. The buffer has room for more pids than the count of now, because
    // processes can start between the two calls. A full buffer can miss pids, so the read tries
    // again with a larger buffer.
    private static func allPIDs() -> [pid_t] {
        var room = Int(max(proc_listallpids(nil, 0), 0)) + 256
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: room)
            let count = pids.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            guard count >= 0 else { return [] }
            if count < room { return Array(pids.prefix(Int(count))) }
            room *= 2
        }
        return []
    }

    private static func usage(of pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    // The CPU times of proc_pid_rusage are in units of the Mach time base. The time base gives
    // nanoseconds.
    private static func cpuTime(ticks: UInt64) -> Duration {
        guard timebase.denom > 0 else { return .zero }
        let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return .nanoseconds(Int64(nanoseconds))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return base
    }()
}
