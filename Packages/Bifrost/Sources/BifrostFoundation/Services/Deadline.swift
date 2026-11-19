// The race of a task against a time limit on the clock. The result is the value of the task when
// it comes first, or nil at the limit or at a cancel of the caller. The race never cancels the
// task: the caller decides. So a caller can give up on a work that a cancel cannot stop at once
// (a call that holds its thread, or a program that must run to its end), and the work goes on.
//
// A task group cannot do this race: the group waits for each child at its end, and a wait for
// the value of a task does not end at a cancel. So the value of the task and the limit go to one
// stream, and the first element wins.
package func firstResult<Value: Sendable>(
    of work: Task<Value, Never>, within limit: Duration, on clock: any Clock<Duration>
) async -> Value? {
    let (first, input) = AsyncStream<Value?>.makeStream()
    let waiter = Task {
        input.yield(await work.value)
    }
    let timer = Task {
        do {
            try await clock.sleep(for: limit)
            input.yield(nil)
        } catch {}
    }
    // The next element is nil at once when the caller is cancelled.
    var race = first.makeAsyncIterator()
    let result = await race.next() ?? nil
    input.finish()
    waiter.cancel()
    timer.cancel()
    return result
}
