import Darwin

// Reads the details of processes with the process APIs of macOS (sysctl, libproc and ioctl). It
// starts no program (user decision, 2026-11-16: each program start is slow on a Mac with an
// endpoint scanner). The app uses SystemProcessInspector. A test gives a fake.
package protocol ProcessInspector: Sendable {
    // The terminal app of each process (TerminalApp.find): a walk up the parents of the
    // process only. A process with no app, and a process that the read cannot see, is in
    // noApp.
    func terminalApps(of pids: [pid_t]) async -> TerminalApps
    // The path of the controlling terminal of the process, for example "/dev/ttys012". nil when
    // the process has no pseudo-terminal or when the read fails.
    func terminalDevice(of pid: pid_t) async -> String?
    // The size of the terminal of a pseudo-terminal device. nil when the read fails, for another
    // device, and for a size that is not valid (TerminalSize.isValid).
    func terminalSize(ofDevice device: String) async -> TerminalSize?
    // The command and the start time of one process. The command is the one of the walk of
    // terminalApps(of:): argv[0], else the path of the executable, else the short name of the
    // kernel. nil when the process does not exist or the read fails.
    func identity(of pid: pid_t) async -> ProcessIdentity?
    // The "claude attach" clients of the processes of the user (AttachClient.of), each with the
    // app of the walk up its parents. own is the PID of the app: a client below it is an attach
    // of Bifrost itself, and it is not in the result. A failed read gives no client.
    func attachClients(own: pid_t) async -> [AttachClient]
}

// The process APIs of macOS. Each read runs off the actor of the caller. No read waits for a
// process, so a read has no time limit.
package struct SystemProcessInspector: ProcessInspector {
    package init() {}

    // For each PID on the walk, proc_pidinfo with PROC_PIDTBSDINFO gives the parent PID. The
    // command is the first argument of the process (argv[0], sysctl with KERN_PROCARGS2), as
    // `ps -o comm=` gives it. The app can read the arguments only of the processes of the user.
    // For another process, or when the read fails, the command is the path of the executable
    // (proc_pidpath), else the short name of the kernel. The walk reads only the processes on
    // the chain of parents, not the whole process table.
    @concurrent package func terminalApps(of pids: [pid_t]) async -> TerminalApps {
        var buffers = Buffers()
        return TerminalApps(of: pids) { pid in
            TerminalApp.find(from: pid) { Self.entry(of: $0, buffers: &buffers) }
        }
    }

    // proc_pidinfo with PROC_PIDTBSDINFO gives the device number of the controlling terminal
    // (e_tdev). devname_r gives its name.
    @concurrent package func terminalDevice(of pid: pid_t) async -> String? {
        Self.device(of: pid)
    }

    // open, ioctl with TIOCGWINSZ, close. The open never makes the device the controlling
    // terminal of the app, and the app never writes to the device (deviceOpenFlags).
    @concurrent package func terminalSize(ofDevice device: String) async -> TerminalSize? {
        Self.size(ofDevice: device)
    }

    @concurrent package func identity(of pid: pid_t) async -> ProcessIdentity? {
        Self.identity(of: pid)
    }

    // One sysctl with KERN_PROC_UID gives each process of the user with its controlling terminal
    // and its start time. claude attach needs a terminal, so only a process with a controlling
    // terminal can be a client, and the scan reads the arguments (KERN_PROCARGS2) only of such a
    // process. Most processes of the user have no terminal, so the scan reads few arguments. A
    // process with more than AttachClient.maxArguments arguments is not a client. The walk of a
    // client reads only the chain of its parents, as terminalApps(of:) does. A process that ends
    // during the scan gives no client.
    @concurrent package func attachClients(own: pid_t) async -> [AttachClient] {
        guard let processes = Self.userProcesses() else { return [] }
        var buffers = Buffers()
        var clients: [AttachClient] = []
        for process in processes where process.kp_eproc.e_tdev != Self.noDevice {
            let pid = process.kp_proc.p_pid
            guard
                let arguments = Self.arguments(
                    of: pid, buffer: &buffers.arguments, limit: AttachClient.maxArguments)
            else { continue }
            let time = process.kp_proc.p_un.__p_starttime
            let started = ProcessStart(
                seconds: UInt64(max(time.tv_sec, 0)), microseconds: UInt64(max(time.tv_usec, 0)))
            let client = AttachClient.of(
                pid: pid, arguments: arguments, started: started, own: own
            ) { Self.entry(of: $0, buffers: &buffers) }
            if let client { clients.append(client) }
        }
        return clients
    }
}

extension SystemProcessInspector {
    // The flags of the open of a terminal device. O_RDONLY: the app never writes to the device.
    // O_NOCTTY: the app never gets a controlling terminal from the device of a session.
    // O_NONBLOCK: the open never waits. O_CLOEXEC: no child process gets the descriptor.
    static let deviceOpenFlags: Int32 = O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC

    // The buffers of the reads of one walk: the arguments of a process are at most
    // KERN_ARGMAX bytes, as ps reads them, and a path is at most PROC_PIDPATHINFO_MAXSIZE bytes
    // (libproc.h; Swift does not import the macro).
    struct Buffers {
        var arguments = [UInt8](repeating: 0, count: SystemProcessInspector.argumentsLimit())
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    }

    // The parent PID and the command of one process, or nil when the read fails (for example
    // for a process that ended).
    static func entry(of pid: pid_t, buffers: inout Buffers) -> ProcessEntry? {
        guard pid > 0, let info = bsdInfo(of: pid) else { return nil }
        return ProcessEntry(
            ppid: pid_t(bitPattern: info.pbi_ppid), comm: command(of: pid, info, &buffers))
    }

    // The command and the start time of one process. The start time comes from a proc_pidinfo
    // call before the read of the command and from one after it. When the two differ, the system
    // gave the PID to a new process during the read, and the result is nil. Thus the command and
    // the start time are always of one process, and the start time is the last read before a
    // kill. The signals of the session actions call it again just before a kill, so it is
    // synchronous.
    package static func identity(of pid: pid_t) -> ProcessIdentity? {
        guard pid > 0, let info = bsdInfo(of: pid) else { return nil }
        var buffers = Buffers()
        let command = command(of: pid, info, &buffers)
        guard let after = bsdInfo(of: pid) else { return nil }
        let started = ProcessStart(
            seconds: after.pbi_start_tvsec, microseconds: after.pbi_start_tvusec)
        let before = ProcessStart(
            seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
        guard started == before else { return nil }
        return ProcessIdentity(command: command, started: started)
    }

    // The BSD information of the process (proc_pidinfo with PROC_PIDTBSDINFO), or nil when the
    // read fails, for example for a process that ended.
    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    // The command of the process: argv[0], else the path of the executable, else the short name
    // of the kernel, at most 16 bytes (for example of a zombie process).
    private static func command(
        of pid: pid_t, _ info: proc_bsdinfo, _ buffers: inout Buffers
    ) -> String {
        if let first = firstArgument(of: pid, buffer: &buffers.arguments) { return first }
        let length = proc_pidpath(pid, &buffers.path, UInt32(buffers.path.count))
        if length > 0 {
            return String(decoding: buffers.path.prefix(Int(length)), as: UTF8.self)
        }
        return withUnsafeBytes(of: info.pbi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // The largest size of the arguments of a process (KERN_ARGMAX), or 0 when the read fails.
    // With 0, each read of the arguments fails, so each command comes from proc_pidpath.
    static func argumentsLimit() -> Int {
        var name = [CTL_KERN, KERN_ARGMAX]
        var limit: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&name, UInt32(name.count), &limit, &size, nil, 0) == 0 else { return 0 }
        return max(Int(limit), 0)
    }

    // argv[0] of the process, from sysctl with KERN_PROCARGS2. nil when the read fails (for
    // example for a process of another user) or when the data has no complete first argument.
    private static func firstArgument(of pid: pid_t, buffer: inout [UInt8]) -> String? {
        readArguments(of: pid, buffer: &buffer).flatMap(firstArgument(inArguments:))
    }

    // argv of the process, from sysctl with KERN_PROCARGS2 (arguments(inArguments:limit:)).
    static func arguments(of pid: pid_t, buffer: inout [UInt8], limit: Int) -> [String]? {
        readArguments(of: pid, buffer: &buffer).flatMap { arguments(inArguments: $0, limit: limit) }
    }

    // The data of sysctl with KERN_PROCARGS2 for the process, in the buffer. nil when the read
    // fails, for example for a process of another user or a process that ended.
    private static func readArguments(of pid: pid_t, buffer: inout [UInt8]) -> ArraySlice<UInt8>? {
        guard !buffer.isEmpty else { return nil }
        var name = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&name, UInt32(name.count), bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return buffer.prefix(min(size, buffer.count))
    }

    // argc and the index of argv[0] in the data of KERN_PROCARGS2, with the parse of ps. The
    // data is argc (an Int32), the path of the executable, NUL bytes, then the arguments and the
    // environment, each with a NUL at its end. ps skips each NUL after the path, so an empty
    // argv[0] gives the next argument. nil when argc is 0 or less, or when the data is shorter
    // than argc.
    private static func argumentsStart(_ data: ArraySlice<UInt8>) -> (count: Int, index: Int)? {
        let countSize = MemoryLayout<Int32>.size
        guard data.count > countSize else { return nil }
        let count = data.prefix(countSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0 else { return nil }
        var index = data.startIndex + countSize
        // The path of the executable, then the NUL bytes after it.
        while index < data.endIndex && data[index] != 0 { index += 1 }
        while index < data.endIndex && data[index] == 0 { index += 1 }
        return (Int(count), index)
    }

    // argv[0] in the data of KERN_PROCARGS2 (argumentsStart). nil when argc is 0 or when no
    // first argument with a NUL at its end follows.
    static func firstArgument(inArguments data: ArraySlice<UInt8>) -> String? {
        guard let start = argumentsStart(data),
            let end = data[start.index...].firstIndex(of: 0)
        else { return nil }
        return String(decoding: data[start.index..<end], as: UTF8.self)
    }

    // The argc arguments in the data of KERN_PROCARGS2 (argumentsStart), from argv[0] on. nil
    // when argc is more than limit, so a long command line costs no parse, and when an argument
    // has no NUL at its end.
    static func arguments(inArguments data: ArraySlice<UInt8>, limit: Int) -> [String]? {
        guard let start = argumentsStart(data), start.count <= limit else { return nil }
        var index = start.index
        var arguments: [String] = []
        for _ in 0..<start.count {
            guard let end = data[index...].firstIndex(of: 0) else { return nil }
            arguments.append(String(decoding: data[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }

    // The device number of no controlling terminal (NODEV: all bits set).
    static let noDevice = dev_t(-1)

    // The processes of the user, from sysctl with KERN_PROC_UID and the effective user ID. nil
    // when the read fails. Processes can start between the size read and the read, so the read
    // has room for 32 more, and it tries again a few times when the list still grew too much.
    static func userProcesses() -> [kinfo_proc]? {
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: geteuid())]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0 else { return nil }
            var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            size = list.count * stride
            let result = list.withUnsafeMutableBytes { bytes in
                sysctl(&name, UInt32(name.count), bytes.baseAddress, &size, nil, 0)
            }
            if result == 0 { return Array(list.prefix(size / stride)) }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    // The path of the controlling terminal of the process. Only a pseudo-terminal gives a path
    // (SessionSizeText.device).
    static func device(of pid: pid_t) -> String? {
        guard pid > 0, let info = bsdInfo(of: pid) else { return nil }
        // NODEV (all bits set): the process has no controlling terminal.
        guard info.e_tdev != UInt32.max else { return nil }
        var name = [CChar](repeating: 0, count: 128)
        let device = dev_t(bitPattern: info.e_tdev)
        guard devname_r(device, S_IFCHR, &name, Int32(name.count)) != nil else { return nil }
        let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return SessionSizeText.device(name: String(decoding: bytes, as: UTF8.self))
    }

    // The size of the terminal of a pseudo-terminal device. Another path gives nil, so the app
    // never opens another device. The read never writes to the device.
    static func size(ofDevice device: String) -> TerminalSize? {
        guard device.hasPrefix("/dev/"),
            SessionSizeText.device(name: String(device.dropFirst("/dev/".count))) == device
        else { return nil }
        let descriptor = open(device, deviceOpenFlags)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var window = winsize()
        guard ioctl(descriptor, TIOCGWINSZ, &window) == 0 else { return nil }
        return SessionSizeText.size(rows: Int(window.ws_row), cols: Int(window.ws_col))
    }
}
