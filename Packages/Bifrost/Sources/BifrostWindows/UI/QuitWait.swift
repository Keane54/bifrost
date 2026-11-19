// The quit of the app waits for its last writes, but for a time limit at most. So a write that
// does not end cannot stop the quit.
//
// The contract of run: done runs one time, on the main thread, when the work ends or when the
// time limit ends, whichever comes first. The limit holds also when the caller blocks the main
// dispatch queue. For example, a quit can call terminate inside a block of the main queue.
// terminateLater then runs a nested run loop, and the main queue cannot drain inside its own
// block, so the work (a task on the main actor) cannot end. Thus the timer of the limit does not
// need the main queue:
// - It sleeps off the main actor, on the clock of the caller.
// - It gives the reply to the main run loop in the common modes, as a perform of a main-actor
//   method on the main thread. The nested run loop of terminateLater runs in a common mode.
// - It also gives the reply to the main actor, for a process that does not run the main run
//   loop.
// The first of these calls runs done. The reply goes one time only.
import Foundation
import Synchronization

@MainActor
public enum QuitWait {
    // The time limit of the wait.
    public static let limit = Duration.seconds(2)

    // Run the work, and call done one time: when the work ends, or when the time limit ends
    // first.
    public static func run(
        limit: Duration = limit, clock: any Clock<Duration> = ContinuousClock(),
        work: @escaping @MainActor () async -> Void, done: @escaping @MainActor () -> Void
    ) {
        let reply = Reply(done)
        let timer = Task.detached {
            do {
                try await clock.sleep(for: limit)
            } catch {
                return
            }
            // A sleep can end after the stop of its timer.
            guard !Task.isCancelled else { return }
            reply.sendFromAnyThread()
        }
        Task {
            await work()
            timer.cancel()
            reply.send()
        }
    }

    // The reply goes one time only.
    private nonisolated final class Reply: NSObject, Sendable {
        private let done: Mutex<(@MainActor () -> Void)?>

        init(_ done: @escaping @MainActor () -> Void) {
            self.done = Mutex(done)
        }

        // Run done, if no reply went before.
        @MainActor func send() {
            let call = done.withLock { done in
                defer { done = nil }
                return done
            }
            call?()
        }

        // Give the reply to the main run loop and to the main actor. The first of the two runs
        // done.
        func sendFromAnyThread() {
            performSelector(
                onMainThread: #selector(sendOnMainThread), with: nil, waitUntilDone: false,
                modes: [RunLoop.Mode.common.rawValue])
            Task { @MainActor in send() }
        }

        // The main run loop runs this method, also inside a block of the main queue.
        @objc @MainActor private func sendOnMainThread() {
            send()
        }
    }
}
