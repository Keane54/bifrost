// One owned worker that runs work on the main actor, one work at a time, in the order of the
// adds. A work starts only after the work before it ended. The worker has one long-lived task.
// When the owner releases the worker, the worker takes no more work, and its task ends after the
// work that waits.
//
// The work runs in the task of the worker, so a cancel of a caller does not reach it. A work that
// must stop on its own (for example a git that a stop ends) makes a task of its own, keeps it so
// that its owner can cancel it, and waits for it.
@MainActor
package final class SerialWork {
    private typealias Work = @MainActor @Sendable () async -> Void

    private let jobs: AsyncStream<Work>.Continuation

    package init() {
        let (stream, jobs) = AsyncStream.makeStream(of: Work.self)
        self.jobs = jobs
        Task {
            for await work in stream { await work() }
        }
    }

    isolated deinit {
        jobs.finish()
    }

    // Add the work. It runs after each work that the worker took before it.
    package func add(_ work: @escaping @MainActor @Sendable () async -> Void) {
        jobs.yield(work)
    }

    // Run the work after each work that the worker took before it, and give its result.
    package func run<Value: Sendable>(
        _ work: @escaping @MainActor @Sendable () async -> Value
    ) async -> Value {
        await withCheckedContinuation { result in
            jobs.yield { result.resume(returning: await work()) }
        }
    }

    // Wait until each work that the worker took before this call ended.
    package func idle() async {
        await run {}
    }
}
