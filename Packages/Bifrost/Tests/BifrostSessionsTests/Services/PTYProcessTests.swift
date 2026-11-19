// The real PTY: /bin/sh scripts in a TemporaryFolder, /usr/bin/env or /usr/bin/perl in place of
// claude (never the real claude). Each test stops each process that it started, by its pid. The
// suite runs one test at a time. Program starts are slow under load on a test host, so each wait
// has a wide limit.
import BifrostTestSupport
import Darwin
import Foundation
import Synchronization
import Testing

@testable import BifrostSessions

// The longest wait of a test for a mark of a script.
private let limit = Duration.seconds(60)

// One event of an attach, as the harness reads it.
private enum AttachEvent: Equatable {
    case data
    case exit(Int32)
}

// One attach of a PTYManager with a script or a program in place of claude.
@MainActor
private final class Harness {
    static let view = PTYView.chat("5a0e0001-0000-4000-8000-000000000001")

    let folder: TemporaryFolder
    let spawner = RecordingPTYSpawner()
    let manager: PTYManager
    let claude: ClaudeRunner
    // The attach of the last open.
    private(set) var attach: PTYAttach?
    private(set) var output: [UInt8] = []
    private(set) var chunkSizes: [Int] = []
    private(set) var exitCode: Int32?
    // Each chunk and the exit, in order.
    private(set) var events: [AttachEvent] = []
    // The time that the reader waits after each chunk. During the wait the reader takes no
    // chunk, so the output waits in the PTY. The wait suspends the reader, so the main actor
    // stays free for the other tests.
    var chunkDelay = Duration.zero

    // The text of the output, with each CR LF as LF. The terminal driver of macOS can write the
    // CR of a LF two times when the child waits on a full PTY (the flow control of PTYProcess
    // lets the PTY fill), so each run of CRs before a LF goes too.
    var text: String {
        let cr = UInt8(ascii: "\r")
        let kept = output.indices.filter { index in
            let next = index + 1 < output.count ? output[index + 1] : 0
            return output[index] != cr || (next != cr && next != UInt8(ascii: "\n"))
        }
        return String(decoding: kept.map { output[$0] }, as: UTF8.self)
    }

    // With a script, the program is the script. The script text can use the folder through
    // FOLDER. With claudeLink, the program is a link named "claude" to /bin/sh, so the command
    // line is "<folder>/claude attach <short id>", as for the real claude: sh runs the script
    // file "attach" in the folder of the open.
    init(
        script: String? = nil, program: String = "/bin/sh", claudeLink: Bool = false,
        environment: [String: String] = ["PATH": "/usr/bin:/bin"]
    ) throws {
        folder = try TemporaryFolder(short: true)
        var path = program
        if let script {
            path = folder.appending("attach")
            let text = "#!/bin/sh\n" + script.replacingOccurrences(of: "FOLDER", with: folder.path)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            if claudeLink {
                path = folder.appending("claude")
                try FileManager.default.createSymbolicLink(
                    atPath: path, withDestinationPath: "/bin/sh")
            }
        }
        claude = ClaudeRunner(path: path, baseEnvironment: environment, runner: NoRunner())
        manager = PTYManager(claude: claude, spawner: spawner)
    }

    // The open waits for the spawn, which runs off the main actor. No close comes during it,
    // so it gives an attach. A task reads its output and its exit.
    func open(
        size: TerminalSize = TerminalSize(cols: 80, rows: 24),
        arguments: [String]? = nil
    ) async throws -> Int32 {
        spawner.use(arguments: arguments)
        let opened = try await manager.open(
            .test(Self.view, shortId: "5a0e0001", directory: folder.path), size: size)
        let attach = try #require(opened, "A close came during the open.")
        self.attach = attach
        Task {
            for await chunk in attach.output {
                received(chunk)
                if chunkDelay > .zero { try? await Task.sleep(for: chunkDelay) }
            }
            guard let code = await attach.exit else { return }
            exitCode = code
            events.append(.exit(code))
        }
        return attach.pid
    }

    private func received(_ chunk: [UInt8]) {
        output += chunk
        chunkSizes.append(chunk.count)
        events.append(.data)
    }

    // Wait until the condition is true, for at most the limit (waitUntil).
    @discardableResult
    func wait(
        sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async -> Bool {
        await waitUntil(within: limit, sourceLocation: sourceLocation, condition)
    }

    @discardableResult
    func waitFor(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await wait(sourceLocation: sourceLocation) { self.text.contains(text) }
    }

    func lines(withPrefix prefix: String) -> [String] {
        text.split(separator: "\n").filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    // Close each PTY (SIGHUP), wait for the reap of each child, then remove the folder.
    func stop() async {
        manager.closeAll()
        _ = await wait { spawner.children.allSatisfy(\.reaped) }
        folder.remove()
    }

    // Run the body, then stop, also when the body throws.
    func run(_ body: (Harness) async throws -> Void) async throws {
        do {
            try await body(self)
        } catch {
            await stop()
            throw error
        }
        await stop()
    }
}

// The BSD details of a process that the test started (proc_pidinfo).
private func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

// A script that waits until a SIGHUP or a SIGTERM. A background sleep holds no descriptor of
// the terminal, and the trap stops it.
private let waitingScript = """
    /bin/sleep 600 </dev/null >/dev/null 2>&1 &
    child=$!
    trap 'kill $child 2>/dev/null; exit 0' HUP TERM
    """

// The wait of a script. A signal that comes after the shell checks for traps, and before the wait
// starts, runs its trap only when the waited process ends. So the loop waits for a short
// sleep: the trap of such a signal runs at the latest one second later.
private let shortWait = "/bin/sleep 1 </dev/null >/dev/null 2>&1 & wait $!"

private let waitLoop = """
    while kill -0 $child 2>/dev/null; do \(shortWait); done
    """

// The modes of a new PTY as `stty -g` prints them: the flags, the control characters and 38400
// baud. The control characters are the defaults of the system.
private let defaultModes =
    "gfmt1:cflag=4b00:iflag=6b02:lflag=5cf:oflag=3:discard=f:dsusp=19:eof=4:eol=ff:eol2=ff"
    + ":erase=7f:intr=3:kill=15:lnext=16:min=1:quit=1c:reprint=12:start=11:status=14:stop=13"
    + ":susp=1a:time=0:werase=17:ispeed=38400:ospeed=38400"

@MainActor
@Suite("PTYProcess", .serialized, .timeLimit(.minutes(2)), .tags(.realProcess))
struct PTYProcessTests {
    // The child is perl with no shell. Perl does not take a terminal
    // itself. A shell such as bash or sh takes one, so a shell script passes also when the spawn
    // gives no controlling terminal. While the child waits for the file
    // "go", proc_pidinfo gives its controlling terminal, its process group and the foreground
    // process group of the terminal. The controlling terminal is the terminal of descriptor 0
    // (ttyname). stty reads the size and the modes of descriptor 0. The modes are the default
    // modes. The child starts in the folder of the open.
    @Test func theChildHasAControllingTerminal() async throws {
        let script = #"""
            use Cwd; use POSIX;
            $| = 1;
            print "tty:", POSIX::ttyname(0), "\n";
            print "size:", `/bin/stty size`;
            print "dir:", Cwd::getcwd(), "\n";
            print "modes:", `/bin/stty -g`;
            print "ready\n";
            select(undef, undef, undef, 0.1) until -e $ARGV[0];
            print "end\n";
            """#
        let harness = try Harness(program: "/usr/bin/perl")
        try await harness.run { harness in
            let go = harness.folder.appending("go")
            let pid = try await harness.open(
                size: TerminalSize(cols: 101, rows: 33), arguments: ["-e", script, go])
            try #require(await harness.waitFor("ready"), "The child did not start.")
            let info = try #require(bsdInfo(pid), "No details of the child.")
            let device = await SystemProcessInspector().terminalDevice(of: pid)
            #expect(device != nil, "No controlling terminal.")
            #expect(harness.lines(withPrefix: "tty:") == [device ?? "none"])
            #expect(getsid(pid) == pid)
            #expect(Int(info.pbi_pgid) == Int(pid))
            #expect(Int(info.e_tpgid) == Int(pid))
            FileManager.default.createFile(atPath: go, contents: nil)
            #expect(await harness.wait { harness.exitCode != nil })
            #expect(harness.exitCode == 0)
            #expect(harness.lines(withPrefix: "size:") == ["33 101"])
            let folder = try #require(realpath(harness.folder.path, nil))
            defer { free(folder) }
            #expect(harness.lines(withPrefix: "dir:") == [String(cString: folder)])
            #expect(harness.lines(withPrefix: "modes:") == [defaultModes])
        }
    }

    // A resize (TIOCSWINSZ on the master) makes the kernel send
    // SIGWINCH to the foreground process group of the terminal. The child is perl with no
    // shell, so the signal comes only when the PTY is its controlling terminal. The handler
    // prints the new size.
    @Test func aResizeSendsSIGWINCHToAChildThatTakesNoTerminalItself() async throws {
        let script = #"""
            $| = 1;
            $SIG{WINCH} = sub { print "winch:", `/bin/stty size` };
            print "ready\n";
            sleep 1 for 1 .. 600;
            """#
        let harness = try Harness(program: "/usr/bin/perl")
        try await harness.run { harness in
            _ = try await harness.open(
                size: TerminalSize(cols: 80, rows: 24), arguments: ["-e", script])
            try #require(await harness.waitFor("ready"), "The child did not start.")
            #expect(harness.lines(withPrefix: "winch:").isEmpty)
            harness.attach?.resize(TerminalSize(cols: 132, rows: 50))
            #expect(await harness.waitFor("winch:50 132"))
        }
    }

    // The test opens three descriptors without FD_CLOEXEC before the open. lsof lists the
    // descriptors of the shell: only 0, 1 and 2, all on the terminal. The shell runs the text
    // of -c, because a shell that reads a script file keeps a descriptor of the file.
    @Test func theChildGetsOnlyDescriptors0To2() async throws {
        let script = """
            [ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo "tty:yes"
            /usr/sbin/lsof -a -p $$ -d 0-1024 -F f
            echo end
            """
        let harness = try Harness(program: "/bin/sh")
        let open = (0..<3).map { _ in Darwin.open("/dev/null", O_RDONLY) }
        defer { for descriptor in open { Darwin.close(descriptor) } }
        try #require(open.allSatisfy { $0 > 2 })
        try await harness.run { harness in
            _ = try await harness.open(arguments: ["-c", script])
            #expect(await harness.wait { harness.exitCode != nil })
            #expect(harness.lines(withPrefix: "tty:") == ["yes"])
            let descriptors = harness.lines(withPrefix: "f").filter { Int($0) != nil }
            #expect(descriptors == ["0", "1", "2"])
        }
    }

    // The program is /usr/bin/env, with no shell, so the env is exactly the env of the child.
    @Test func theChildEnvIsTheChildEnvironmentWithTermAndColorterm() async throws {
        let base = [
            "PATH": "/usr/bin:/bin", "HOME": "/nonexistent-bifrost-home", "LANG": "en_US.UTF-8",
            "KEEP": "a = b", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
            "TERM_PROGRAM": "x", "TERM_SESSION_ID": "y", "WARP_X": "1", "TERM": "dumb",
            "COLORTERM": "no",
        ]
        let harness = try Harness(program: "/usr/bin/env", environment: base)
        try await harness.run { harness in
            _ = try await harness.open(arguments: ["-0"])
            #expect(await harness.wait { harness.exitCode != nil })
            var env: [String: String] = [:]
            for entry in harness.output.split(separator: 0) {
                let text = String(decoding: entry, as: UTF8.self)
                guard let equals = text.firstIndex(of: "=") else { continue }
                env[String(text[..<equals])] = String(text[text.index(after: equals)...])
            }
            #expect(env == ChildEnvironment.make(from: harness.claude.environment, pty: true))
            #expect(
                env == [
                    "PATH": "/usr/bin:/bin", "HOME": "/nonexistent-bifrost-home",
                    "LANG": "en_US.UTF-8", "KEEP": "a = b", "TERM": "xterm-256color",
                    "COLORTERM": "truecolor",
                ])
        }
    }

    // The WINCH trap prints the size that the resize set.
    @Test func aResizeReachesTheChild() async throws {
        let harness = try Harness(
            script: waitingScript + """

                trap 'echo "size:$(/bin/stty size)"' WINCH
                echo ready
                """ + "\n" + waitLoop)
        try await harness.run { harness in
            _ = try await harness.open(size: TerminalSize(cols: 80, rows: 24))
            try #require(await harness.waitFor("ready"), "The script did not start.")
            harness.attach?.resize(TerminalSize(cols: 132, rows: 50))
            #expect(await harness.waitFor("size:50 132"))
        }
    }

    // The trap records each SIGHUP of the attach child, and the state of the
    // terminal: a write to the terminal works only while the master is open. A close sends one
    // SIGHUP, by the pid of the child, while the master is open. A sibling in the process group
    // of the script records each SIGHUP too, and gets none while the master is open. A stand-in
    // session process in its own process group lives on.
    @Test func aCloseSendsSIGHUPOnlyToTheAttachChild() async throws {
        let standIn = try StandInProcess()
        defer { standIn.stop() }
        let harness = try Harness(
            script: """
                n=0
                trap 'if printf "hup\\r\\n" 2>/dev/null; then echo open >> FOLDER/log; \
                else echo closed >> FOLDER/log; fi; n=$((n+1))' HUP
                (
                  /bin/sleep 600 </dev/null >/dev/null 2>&1 &
                  s=$!
                  trap 'if printf "sibling\\r\\n" 2>/dev/null; then echo open >> FOLDER/sibling; \
                  else echo closed >> FOLDER/sibling; fi' HUP
                  trap 'kill $s 2>/dev/null; exit 0' TERM
                  : > FOLDER/sibling-ready
                  while kill -0 $s 2>/dev/null; do \(shortWait); done
                ) &
                sibling=$!
                /bin/sleep 600 </dev/null >/dev/null 2>&1 &
                child=$!
                until [ -e FOLDER/sibling-ready ]; do /bin/sleep 0.1; done
                echo ready
                while [ $n -eq 0 ] && kill -0 $child 2>/dev/null; do \(shortWait); done
                /bin/sleep 1
                kill $child 2>/dev/null
                kill $sibling 2>/dev/null
                wait $sibling
                : > FOLDER/done
                exit 0
                """)
        try await harness.run { harness in
            let pid = try await harness.open()
            try #require(await harness.waitFor("ready"), "The script did not start.")
            harness.attach?.close()
            let done = harness.folder.appending("done")
            #expect(await harness.wait { FileManager.default.fileExists(atPath: done) })
            #expect(await harness.wait { harness.spawner.children.allSatisfy(\.reaped) })
            let log = try String(contentsOfFile: harness.folder.appending("log"), encoding: .utf8)
            #expect(log == "open\n")
            let sibling =
                (try? String(contentsOfFile: harness.folder.appending("sibling"), encoding: .utf8))
                ?? ""
            #expect(!sibling.split(separator: "\n").contains("open"), "The sibling got a SIGHUP.")
            #expect(harness.spawner.log.kills == [.init(pid, SIGHUP)])
            #expect(standIn.alive, "The stand-in session ended.")
        }
    }

    // After the exit (the reap), a signal and a close send nothing.
    @Test func noSignalAfterTheChildWasReaped() async throws {
        let harness = try Harness(script: "echo bye\nexit 3")
        try await harness.run { harness in
            _ = try await harness.open()
            #expect(await harness.wait { harness.exitCode != nil })
            #expect(harness.exitCode == 3)
            #expect(harness.text.contains("bye"))
            let child = try #require(harness.spawner.children.first)
            #expect(child.reaped)
            child.signal(.hangup)
            child.signal(.terminate)
            harness.attach?.close()
            harness.manager.closeAll()
            #expect(harness.spawner.log.kills.isEmpty)
        }
    }

    // The exit comes after the drain of the last byte, also when the output needs more than one
    // drain. The reader waits 30 ms after each chunk, so the output waits in the PTY when the
    // child ends: a drain is still in flight at the exit.
    @Test func theExitCodeComesAfterTheLastOutput() async throws {
        let harness = try Harness(script: "/usr/bin/seq -f 'line %g' 1 100000\necho last\nexit 7")
        harness.chunkDelay = .milliseconds(30)
        try await harness.run { harness in
            _ = try await harness.open()
            #expect(await harness.wait { harness.exitCode != nil })
            #expect(harness.exitCode == 7)
            #expect(harness.events.last == .exit(7))
            #expect(harness.events.filter { $0 != .data }.count == 1)
            let expected = (1...100_000).map { "line \($0)" } + ["last"]
            #expect(harness.text.split(separator: "\n").map(String.init) == expected)
        }
    }

    // Each drain is at most 262,144 bytes, and the lines keep their order. The time that the main
    // actor stays free is for the performance pass (tools/bench), not for a unit test.
    @Test func aBurstOf20000LinesKeepsTheOrderAndTheDrainLimit() async throws {
        let harness = try Harness(script: "/usr/bin/seq -f 'line %g' 1 20000")
        try await harness.run { harness in
            _ = try await harness.open()
            #expect(await harness.wait { harness.exitCode != nil })
            #expect(harness.exitCode == 0)
            #expect(harness.text.split(separator: "\n").map(String.init) == (1...20_000).map {
                "line \($0)"
            })
            #expect(harness.chunkSizes.allSatisfy { $0 <= PTYAttach.drainLimit })
        }
    }

    // The write takes the whole paste, and the child gets each byte in order. The terminal is
    // raw, so the line rules change no byte. The time of the write call is for the performance
    // pass (tools/bench), not for a unit test.
    @Test func aOneMegabytePasteReachesTheChildInOrder() async throws {
        let harness = try Harness(
            script: """
                /bin/stty raw -echo
                echo ready
                /usr/bin/head -c 1048576 > FOLDER/out
                echo done
                """)
        try await harness.run { harness in
            _ = try await harness.open()
            try #require(await harness.waitFor("ready"), "The script did not start.")
            let bytes = (0..<1_048_576).map { UInt8(0x21 + $0 % 94) }
            #expect(harness.attach?.write(bytes) == true)
            #expect(await harness.waitFor("done"))
            let out = FileManager.default.contents(atPath: harness.folder.appending("out"))
            #expect(out == Data(bytes))
        }
    }

    // an open that cannot start gives the native error text, and starts no process.
    @Test func aSpawnFailureGivesTheNativeErrorText() async throws {
        let harness = try Harness(script: "exit 0")
        try await harness.run { harness in
            let missing = harness.folder.appending("missing")
            let size = TerminalSize(cols: 80, rows: 24)
            let script = harness.folder.appending("attach")
            let noFolder = PTYError(
                message: "Cannot start \(script) in \(missing): No such file or directory.")
            await #expect(throws: noFolder) {
                try await harness.manager.open(
                    .test(Harness.view, shortId: "5a0e0001", directory: missing), size: size)
            }
            let other = PTYManager(
                claude: ClaudeRunner(path: missing, baseEnvironment: [:], runner: NoRunner()))
            let noProgram = PTYError(message: "Cannot start \(missing): No such file or directory.")
            await #expect(throws: noProgram) {
                try await other.open(
                    .test(Harness.view, shortId: "5a0e0001", directory: harness.folder.path),
                    size: size)
            }
            #expect(harness.manager.attach(Harness.view) == nil)
            #expect(other.attach(Harness.view) == nil)
            #expect(harness.spawner.children.isEmpty)
        }
    }

    // The system inspector reads only processes that the test started, and
    // the parents of the test process. The child is the shell of a script on a PTY of the test,
    // the leader of its own process group, and the PTY is its controlling terminal. The read of
    // the child gives its parent PID and its command. The command is argv[0], as `ps -o comm=`
    // gives it (KERN_PROCARGS2). The kernel runs the script with argv[0] "/bin/sh", and the path
    // of that executable is /bin/bash, so only argv[0] gives "/bin/sh". The walk of the terminal
    // app from the child goes through the test process, so it gives the app of the test process.
    // The size of the device is the size of the open, and then the size of a resize (TIOCSWINSZ
    // on the master). The reader keeps the device and reads the new size.
    @Test func theSystemInspectorReadsAChildThatTheTestStarted() async throws {
        let harness = try Harness(script: waitingScript + "\necho ready\n" + waitLoop)
        try await harness.run { harness in
            let pid = try await harness.open(size: TerminalSize(cols: 77, rows: 21))
            try #require(await harness.waitFor("ready"), "The script did not start.")
            let child = pid
            var buffers = SystemProcessInspector.Buffers()
            let entry = SystemProcessInspector.entry(of: child, buffers: &buffers)
            #expect(entry == ProcessEntry(ppid: getpid(), comm: "/bin/sh"))
            let inspector = SystemProcessInspector()
            let me = getpid()
            let read = await inspector.terminalApps(of: [child, me])
            #expect(Set(read.apps.keys).union(read.noApp) == [child, me])
            #expect(read.apps[child] == read.apps[me])
            let device = try #require(await inspector.terminalDevice(of: child))
            #expect(device.hasPrefix("/dev/ttys"))
            let start = await inspector.terminalSize(ofDevice: device)
            #expect(start == TerminalSize(cols: 77, rows: 21))
            let reader = SessionSizeReader(inspector: inspector)
            #expect(await reader.read(pid: child) == TerminalSize(cols: 77, rows: 21))
            harness.attach?.resize(TerminalSize(cols: 90, rows: 30))
            #expect(await reader.read(pid: child) == TerminalSize(cols: 90, rows: 30))
        }
    }

    // The scan of the attach clients finds a child of the test with the command line
    // "<folder>/claude attach 5a0e0001" on a PTY of the test. The scan reads all processes of
    // the user, but the test looks only at its own child. The start time is the one of
    // identity(of:), and the app is the app of the test process, as in the walk of
    // terminalApps(of:). With the PID of the test process as the own PID, the child is an
    // attach of the app itself and is not a client.
    @Test func theSystemScanFindsAnAttachClientThatTheTestStarted() async throws {
        let harness = try Harness(
            script: waitingScript + "\necho ready\n" + waitLoop, claudeLink: true)
        try await harness.run { harness in
            let child = try await harness.open()
            try #require(await harness.waitFor("ready"), "The script did not start.")
            let inspector = SystemProcessInspector()
            let me = getpid()
            let clients = await inspector.attachClients(own: 0)
            let found = try #require(clients.first { $0.pid == child })
            #expect(found.argument == .idStart("5a0e0001"))
            #expect(found.started == (await inspector.identity(of: child))?.started)
            #expect(found.app == (await inspector.terminalApps(of: [me])).apps[me])
            let own = await inspector.attachClients(own: me)
            #expect(!own.contains { $0.pid == child })
        }
    }
}

// The flow control of a PTYProcess with no reader: the read of the master stops while too many
// bytes wait, so the memory of the app does not grow with the output of the child.
@Suite("PTY flow control", .serialized, .timeLimit(.minutes(2)), .tags(.realProcess))
struct PTYFlowControlTests {
    // The child writes 4 MiB. With no drain, the read stops when more than highWater bytes
    // wait, so the bytes that wait never pass highWater and one read, and the child waits on its
    // write. Then each drain can start the read again, and each byte comes before the exit.
    @MainActor
    @Test func theReadStopsWhileTooManyBytesWaitAndStartsAgainAfterADrain() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let size = 64 * 65_536
        let process = try PTYProcess(
            program: "/bin/sh",
            arguments: ["-c", "/bin/dd if=/dev/zero bs=65536 count=64 2>/dev/null; printf end"],
            environment: ["PATH": "/usr/bin:/bin"], directory: folder.path,
            size: TerminalSize(cols: 80, rows: 24))
        // A failed check stops the child, so it does not wait on its write for ever.
        defer { process.signal(.terminate) }
        await waitUntil(within: limit) { process.isPaused }
        #expect(process.waitingCount > PTYProcess.highWater)
        #expect(process.waitingCount <= PTYProcess.highWater + PTYProcess.readSize)
        var received = 0
        var last: [UInt8] = []
        var code: Int32?
        for await event in process.events {
            switch event {
            case .bytesWaiting:
                let bytes = process.drain(limit: PTYAttach.drainLimit)
                received += bytes.count
                last = Array((last + bytes).suffix(3))
            case .exited(let exit):
                code = exit
            }
        }
        #expect(code == 0)
        #expect(received == size + 3)
        #expect(last == Array("end".utf8))
        #expect(!process.isPaused)
    }
}

// The bytes that wait for a drain.
@Suite("the waiting bytes")
struct ByteQueueTests {
    @Test func aTakeGivesTheFirstBytesInOrderAcrossChunks() {
        var queue = ByteQueue()
        for chunk in 0..<1_000 { queue.append([UInt8(truncatingIfNeeded: chunk)]) }
        queue.append([])
        #expect(queue.count == 1_000)
        var out: [UInt8] = []
        while !queue.isEmpty { out += queue.take(7) }
        #expect(out == (0..<1_000).map { UInt8(truncatingIfNeeded: $0) })
        #expect(queue.take(5).isEmpty)
    }

    @Test func aTakeCanSplitAChunkAndTheRestStays() {
        var queue = ByteQueue()
        queue.append([1, 2, 3, 4, 5])
        queue.append([6, 7])
        #expect(queue.take(2) == [1, 2])
        #expect(queue.take(4) == [3, 4, 5, 6])
        queue.append([8])
        #expect(queue.count == 2)
        #expect(queue.take(10) == [7, 8])
        #expect(queue.isEmpty)
        #expect(queue.take(0).isEmpty)
    }
}
