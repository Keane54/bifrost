// The session size: the device and size texts, the range of a terminal size, the reader and the
// watcher. The process inspector is a fake, so no test reads a process. The
// watcher runs on a ManualClock.
import BifrostTestSupport
import Darwin
import Testing

@testable import BifrostSessions

// The device is /dev/ttys012. The size is 32 rows and 120 columns, or the size read fails when
// sizeWorks is false.
private func fake(sizeWorks: Bool = true) -> FakeProcessInspector {
    FakeProcessInspector(
        device: "/dev/ttys012", size: sizeWorks ? TerminalSize(cols: 120, rows: 32) : nil)
}

@Suite("session size text", .timeLimit(.minutes(1)))
struct SessionSizeTextTests {
    @Test("the device path is read and ?? and other text are refused")
    func theDevice() {
        #expect(SessionSizeText.device(name: "ttys012") == "/dev/ttys012")
        #expect(SessionSizeText.device(name: "??") == nil)
        #expect(SessionSizeText.device(name: "") == nil)
        #expect(SessionSizeText.device(name: "../etc") == nil)
    }

    @Test("rows are read before columns")
    func theSize() {
        #expect(SessionSizeText.size(rows: 32, cols: 120) == TerminalSize(cols: 120, rows: 32))
        #expect(SessionSizeText.size(rows: 0, cols: 0) == nil)
        #expect(SessionSizeText.size(rows: 32, cols: 1001) == nil)
        #expect(SessionSizeText.size(rows: 1001, cols: 80) == nil)
    }

    // the device opens only to read, never as the controlling terminal of the app, and
    // the open never waits. No child process gets the descriptor.
    @Test func theDeviceOpensReadOnlyAndNeverAsTheControllingTerminal() {
        let flags = SystemProcessInspector.deviceOpenFlags
        #expect(flags & O_ACCMODE == O_RDONLY)
        #expect(flags & O_NOCTTY == O_NOCTTY)
        #expect(flags & O_NONBLOCK == O_NONBLOCK)
        #expect(flags & O_CLOEXEC == O_CLOEXEC)
    }
}

@Suite("terminal size", .timeLimit(.minutes(1)))
struct TerminalSizeTests {
    @Test("only whole numbers from 1 to 1000 are accepted")
    func theRange() {
        for good in [1, 80, 1000] { #expect(TerminalSize.isValid(good)) }
        for bad in [0, 1001, -3] { #expect(!TerminalSize.isValid(bad)) }
        #expect(TerminalSize(cols: 80, rows: 24).isValid)
        #expect(!TerminalSize(cols: 80, rows: 0).isValid)
        #expect(!TerminalSize(cols: 1001, rows: 24).isValid)
    }
}

@MainActor
@Suite("session size reader", .timeLimit(.minutes(1)))
struct SessionSizeReaderTests {
    @Test func theDeviceOfThePidThenTheSizeOfTheDevice() async {
        let inspector = fake()
        let reader = SessionSizeReader(inspector: inspector)
        #expect(await reader.read(pid: 672) == TerminalSize(cols: 120, rows: 32))
        #expect(inspector.calls == [.terminalDevice(672), .terminalSize("/dev/ttys012")])
    }

    @Test func noTTYGivesNoSize() async {
        let inspector = FakeProcessInspector(device: nil, size: TerminalSize(cols: 120, rows: 32))
        let reader = SessionSizeReader(inspector: inspector)
        #expect(await reader.read(pid: 672) == nil)
        #expect(inspector.calls == [.terminalDevice(672)])
    }

    @Test func aFailedSizeReadGivesNoSize() async {
        let inspector = fake(sizeWorks: false)
        let reader = SessionSizeReader(inspector: inspector)
        #expect(await reader.read(pid: 5) == nil)
        #expect(inspector.calls == [.terminalDevice(5), .terminalSize("/dev/ttys012")])
    }

    @Test func eachReadReadsTheDeviceAgain() async {
        let inspector = fake()
        let reader = SessionSizeReader(inspector: inspector)
        #expect(await reader.read(pid: 5) == TerminalSize(cols: 120, rows: 32))
        #expect(await reader.read(pid: 5) == TerminalSize(cols: 120, rows: 32))
        #expect(
            inspector.calls == [
                .terminalDevice(5), .terminalSize("/dev/ttys012"),
                .terminalDevice(5), .terminalSize("/dev/ttys012"),
            ])
    }

    // A new process can get the pid of a process that ended. Its size comes from its own device.
    @Test func aReusedPidGivesTheSizeOfTheNewDevice() async {
        let inspector = fake()
        let reader = SessionSizeReader(inspector: inspector)
        _ = await reader.read(pid: 5)
        inspector.device = "/dev/ttys013"
        _ = await reader.read(pid: 5)
        #expect(inspector.calls.last == .terminalSize("/dev/ttys013"))
    }

    // The reads run off the main actor, also with a fake inspector.
    @Test func theReadsRunOffTheMainActor() async {
        let inspector = fake()
        let reader = SessionSizeReader(inspector: inspector)
        _ = await reader.read(pid: 5)
        #expect(inspector.mainThreadCalls == 0)
    }
}

// MARK: - The watcher

// The reads and the emits of a watcher test.
@MainActor
private final class WatchLog {
    var reads: [pid_t] = []
    var emits: [(view: String, size: TerminalSize)] = []
}

private let size1 = TerminalSize(cols: 120, rows: 32)
private let size2 = TerminalSize(cols: 80, rows: 24)

// A watcher of the view "chat:a" whose read gives the next size of the log, or waits for the
// test (hold).
@MainActor
private final class WatchRig {
    // The answers of the reads.
    @MainActor
    final class Reads {
        var sizes: [TerminalSize] = [size1]
        var pid: pid_t? = 5
        // True: the first read waits until release.
        var hold = false
        var held: CheckedContinuation<TerminalSize?, Never>?
    }

    let clock = ManualClock()
    let log = WatchLog()
    let reads = Reads()
    let watcher: SessionSizeWatcher<String>

    init() {
        let (log, reads) = (log, reads)
        watcher = SessionSizeWatcher<String>(
            read: { pid in
                log.reads.append(pid)
                if reads.hold && log.reads.count == 1 {
                    return await withCheckedContinuation { reads.held = $0 }
                }
                return reads.sizes.count > 1 ? reads.sizes.removeFirst() : reads.sizes.first
            }, pidOf: { _ in reads.pid }, emit: { log.emits.append(($0, $1)) }, clock: clock)
    }

    // The timer of the poke sleeps: move the clock by the time. The timer is not due: it still
    // sleeps, or it sleeps again to the deadline that a later poke moved.
    func step(_ ms: Int) async {
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(ms))
        await clock.waitForSleepers(1)
    }

    // The timer of the poke sleeps: move the clock by the time, and wait until its run ended.
    // The read of the run must not wait for the test.
    func fire(_ ms: Int) async {
        await clock.waitForSleepers(1)
        let task = watcher.task(of: "chat:a")
        clock.advance(by: .milliseconds(ms))
        await task?.value
    }

    func release(_ size: TerminalSize) {
        reads.held?.resume(returning: size)
        reads.held = nil
    }
}

@MainActor
@Suite("SessionSizeWatcher", .timeLimit(.minutes(1)))
struct SessionSizeWatcherTests {
    @Test func oneReadAfterABurst() async {
        let rig = WatchRig()
        rig.watcher.poke("chat:a")
        await rig.step(100)
        rig.watcher.poke("chat:a")
        await rig.step(100)
        rig.watcher.poke("chat:a")
        #expect(rig.log.reads.isEmpty)
        await rig.fire(150)
        #expect(rig.log.reads == [5])
        #expect(rig.log.emits.map(\.view) == ["chat:a"])
        #expect(rig.log.emits.map(\.size) == [size1])
    }

    @Test func onlyAChangedSizeEmits() async {
        let rig = WatchRig()
        rig.reads.sizes = [size1, size1, size2]
        for _ in 0..<3 {
            rig.watcher.poke("chat:a")
            await rig.fire(200)
        }
        #expect(rig.log.reads.count == 3)
        #expect(rig.log.emits.map(\.view) == ["chat:a", "chat:a"])
        #expect(rig.log.emits.map(\.size) == [size1, size2])
    }

    // A view with no pid reads nothing. After forget, the same size emits again.
    @Test func noPidReadsNothingAndForgetEmitsAgain() async {
        let rig = WatchRig()
        rig.reads.pid = nil
        rig.watcher.poke("chat:a")
        await rig.fire(200)
        #expect(rig.log.reads.isEmpty)
        rig.reads.pid = 7
        rig.watcher.poke("chat:a")
        await rig.fire(200)
        #expect(rig.log.emits.count == 1)
        rig.watcher.forget("chat:a")
        rig.watcher.poke("chat:a")
        await rig.fire(200)
        #expect(rig.log.emits.count == 2)
        // A poke before forget gives no read: the next poke is the only read after it.
        rig.watcher.poke("chat:a")
        rig.watcher.forget("chat:a")
        rig.watcher.poke("chat:a")
        await rig.fire(200)
        #expect(rig.log.reads.count == 3)
    }

    // A poke and a forget in the timer of a read: the read of the forgotten poke never runs, and
    // the next poke reads the size again.
    @Test func forgetClearsTheLastSize() async {
        let rig = WatchRig()
        rig.watcher.poke("chat:a")
        await rig.fire(200)
        rig.watcher.poke("chat:a")
        rig.watcher.forget("chat:a")
        rig.watcher.poke("chat:a")
        await rig.fire(200)
        #expect(rig.log.reads.count == 2)
        #expect(rig.log.emits.count == 2)
    }

    // A poke during a read gives one more read after it, never a second read at the same time.
    @Test func oneReadAtATime() async {
        let rig = WatchRig()
        rig.reads.hold = true
        rig.reads.sizes = [size2]
        rig.watcher.poke("chat:a")
        await rig.clock.waitForSleepers(1)
        rig.clock.advance(by: .milliseconds(200))
        await waitUntil { rig.log.reads.count == 1 }
        rig.watcher.poke("chat:a")
        await rig.fire(200)
        #expect(rig.log.reads.count == 1)
        rig.release(size1)
        // The end of the read pokes again: one more read after the debounce.
        await rig.fire(200)
        #expect(rig.log.reads.count == 2)
        #expect(rig.log.emits.map(\.size) == [size1, size2])
    }

    // A read that ends after forget of its view emits nothing, and the next poke reads again.
    @Test func aReadThatEndsAfterForgetEmitsNothing() async {
        let rig = WatchRig()
        rig.reads.hold = true
        rig.reads.sizes = [size2]
        rig.watcher.poke("chat:a")
        let task = rig.watcher.task(of: "chat:a")
        await rig.clock.waitForSleepers(1)
        rig.clock.advance(by: .milliseconds(200))
        await waitUntil { rig.log.reads.count == 1 }
        rig.watcher.forget("chat:a")
        rig.release(size1)
        await task?.value
        #expect(rig.log.emits.isEmpty)
        rig.watcher.poke("chat:a")
        await rig.fire(200)
        #expect(rig.log.emits.map(\.size) == [size2])
    }

    @Test func theDefaultDebounceIs150ms() async {
        let rig = WatchRig()
        rig.watcher.poke("chat:a")
        await rig.step(149)
        #expect(rig.log.reads.isEmpty)
        await rig.fire(1)
        #expect(rig.log.reads == [5])
    }
}
