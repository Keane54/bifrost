import Dispatch

// The executor of the calls that can wait a long time: a process or PTY spawn (the endpoint
// scanner of the Mac can hold it), a Launch Services lookup and a poll. Such a call holds its
// thread until it returns. The cooperative pool of Swift has one thread for each CPU core, so a
// few such calls on the pool stop each other async job of the app.
//
// The executor runs its jobs on a concurrent dispatch queue. When a job blocks, GCD gives the
// queue another thread, so a blocked call holds only its own thread. Run a call with
// BlockingExecutor.run, or run a whole async function on it with
// withTaskExecutorPreference(BlockingExecutor.shared).
package final class BlockingExecutor: TaskExecutor {
    package static let shared = BlockingExecutor()
    // The label of the queue. A test reads it.
    static let label = "bifrost.blocking"

    private let queue = DispatchQueue(label: label, attributes: .concurrent)

    private init() {}

    package func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }

    // Run the work on a thread of the executor, and give its result or its error. The calling
    // task waits with no thread.
    @concurrent package static func run<Value: Sendable, Failure: Error>(
        _ work: @Sendable () throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        try await withTaskExecutorPreference(shared) { () async throws(Failure) -> Value in
            try work()
        }
    }

    // Run the work on a thread of the executor, and race it against the time limit on the clock
    // (firstResult). The first result wins: the value of the work, or the fallback at the limit.
    // A cancel of the caller also gives the fallback. Use it for a read that can hang, for
    // example a stat on a network volume that is offline. A work that hangs cannot be stopped:
    // its task keeps its own thread of the executor until the work returns, and its result then
    // goes nowhere.
    // The limit counts from the start of the work, not from the call. On a busy Mac the work can
    // wait for a thread of the executor first, and that wait is not a hang: a limit that counted
    // it gave the fallback for a read that never started, for example "missing" for a folder
    // that exists.
    @concurrent package static func run<Value: Sendable>(
        within limit: Duration, on clock: any Clock<Duration>, else fallback: Value,
        _ work: @escaping @Sendable () async -> Value
    ) async -> Value {
        await run(executor: shared, within: limit, on: clock, else: fallback, work)
    }

    // The run with a time limit on the executor. A test gives an executor that holds its jobs,
    // so that it can move the clock while the work waits for its start.
    @concurrent static func run<Value: Sendable>(
        executor: any TaskExecutor, within limit: Duration, on clock: any Clock<Duration>,
        else fallback: Value, _ work: @escaping @Sendable () async -> Value
    ) async -> Value {
        let (starts, start) = AsyncStream<Void>.makeStream()
        let worker = Task(executorPreference: executor) {
            start.yield()
            start.finish()
            return await work()
        }
        // The wait for the start ends with nil at a cancel of the caller.
        var started = starts.makeAsyncIterator()
        guard await started.next() != nil else {
            worker.cancel()
            return fallback
        }
        let result = await firstResult(of: worker, within: limit, on: clock)
        worker.cancel()
        return result ?? fallback
    }
}
