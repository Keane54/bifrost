// The delay of the main thread: the longest pass of the main run loop in each 60 s window.
// Safety: the run loop test runs the run loop of its own thread until its work ends, for less
// than a second.
import CoreFoundation
import Foundation
import Synchronization
import Testing

@testable import BifrostHealth

@Suite("performance main thread watch")
struct MainThreadWatchTests {
    @Test func theLongestPassIn60sIsKept() {
        var window = PassWindow()
        window.record(.milliseconds(40), at: .seconds(1))
        window.record(.milliseconds(250), at: .seconds(20))
        window.record(.milliseconds(90), at: .seconds(59))
        // No window has ended yet.
        #expect(window.longest(at: .seconds(59)) == nil)
        // The first window ended: its longest pass counts for the next 60 s.
        #expect(window.longest(at: .seconds(60)) == .milliseconds(250))
        window.record(.milliseconds(30), at: .seconds(70))
        #expect(window.longest(at: .seconds(119)) == .milliseconds(250))
        #expect(window.longest(at: .seconds(120)) == .milliseconds(30))
    }

    @Test func aWindowWithNoPassGivesNothing() {
        var window = PassWindow()
        window.record(.milliseconds(500), at: .seconds(10))
        // The run loop slept for the whole second window.
        #expect(window.longest(at: .seconds(130)) == nil)
        window.record(.milliseconds(20), at: .seconds(150))
        #expect(window.longest(at: .seconds(180)) == .milliseconds(20))
    }

    @Test func aStartAndAStopChangeNothingElse() {
        let watch = MainThreadWatch()
        watch.start()
        watch.start()
        #expect(watch.longest() == nil)
        watch.stop()
        watch.stop()
    }

    @Test func thePassStartsFirstAndEndsLast() throws {
        let watch = MainThreadWatch()
        watch.start()
        defer { watch.stop() }
        let observers = watch.installedObservers
        #expect(observers.map(CFRunLoopObserverGetOrder) == [CFIndex.min, CFIndex.max])
        #expect(
            observers.map(CFRunLoopObserverGetActivities) == [
                CFRunLoopActivity.afterWaiting.rawValue, CFRunLoopActivity.beforeWaiting.rawValue,
            ])
    }

    // A timer does 150 ms of work. A later beforeWaiting observer, as the display cycle and the
    // commit of Core Animation are, does 100 ms more. The pass has both. The run loop is the one of
    // a thread of the test, so no other job of the test process runs in it. The run loop stops
    // after the pass, not at a time, so a slow start of the thread changes nothing.
    @Test func aPassHasTheWorkOfTheLateObservers() {
        let result = Mutex<Duration?>(nil)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.withLock { $0 = passOfLateWork() }
            finished.signal()
        }
        thread.start()
        #expect(finished.wait(timeout: .now() + 60) == .success)
        let pass = result.withLock { $0 }
        #expect((pass ?? .zero) >= .milliseconds(240))
    }

    @Test func aDroppedWatchRemovesItsObservers() {
        var watch: MainThreadWatch? = MainThreadWatch()
        watch?.start()
        let observers = watch?.installedObservers ?? []
        #expect(observers.count == 2)
        #expect(observers.allSatisfy(CFRunLoopObserverIsValid))
        watch = nil
        #expect(!observers.contains(where: CFRunLoopObserverIsValid))
    }
}

// The flag of the late work of a run loop test. The run loop calls each block on its own thread.
private final class RunLoopWork: @unchecked Sendable {
    var armed = false
}

// Work on the thread for the time: a slow pass of the run loop.
private func spin(_ time: Duration) {
    let clock = ContinuousClock()
    let end = clock.now + time
    while clock.now < end {}
}

// Runs on a thread of the test: watches the run loop of this thread, does the work of a timer and
// of a late observer in it, and gives the longest pass. The thread owns the run loop and the flag.
// After its work, the late observer adds a timer that is due at once. That timer stops the run
// loop in the next pass, so the watch records the pass of the work first (its last observer comes
// after the late observer).
private func passOfLateWork() -> Duration? {
    let watch = MainThreadWatch(runLoop: CFRunLoopGetCurrent())
    let loop = CFRunLoopGetCurrent()!
    watch.start()
    defer { watch.stop() }
    let late = RunLoopWork()
    let observer = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_000
    ) { _, _ in
        guard late.armed else { return }
        late.armed = false
        spin(.milliseconds(100))
        let stop = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0, 0, 0
        ) { _ in CFRunLoopStop(loop) }!
        CFRunLoopAddTimer(loop, stop, .defaultMode)
    }!
    CFRunLoopAddObserver(loop, observer, .defaultMode)
    defer { CFRunLoopObserverInvalidate(observer) }
    let now = CFAbsoluteTimeGetCurrent()
    let work = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, now + 0.05, 0, 0, 0) { _ in
        spin(.milliseconds(150))
        late.armed = true
    }!
    // A run loop mode with no timer ends the run at once, so this timer keeps the mode busy
    // until the stop. It fires only for a run loop that never gets to the stop.
    let keep = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, now + 60, 0, 0, 0) { _ in
        CFRunLoopStop(loop)
    }!
    defer { CFRunLoopTimerInvalidate(keep) }
    CFRunLoopAddTimer(loop, work, .defaultMode)
    CFRunLoopAddTimer(loop, keep, .defaultMode)
    _ = CFRunLoopRunInMode(.defaultMode, 60, false)
    return watch.longestInThisWindow
}
