import Synchronization

// One value that loads before its use, so the use is quick. The speech engine keeps the analyzer
// of the next session in it. The state is in a Mutex.
// - A take uses the value one time. With no value, it waits for the load that runs, or starts
//   one. A load that fails runs again, three loads at most.
// - One load runs at a time.
// - A release starts a new epoch: the value goes, and the load that runs gets a cancel. A load of
//   an older epoch keeps nothing. A take or a loadNext of an older epoch fails or does nothing.
final class Preload<Key: Sendable, Value: Sendable>: Sendable {
    enum Failure: Error, Equatable {
        // A release came after the start of the call.
        case released
        // The load failed: one time for a prepare, three times for a take.
        case loadFailed
    }

    private struct State {
        var value: Value?
        var loading: Task<Void, any Error>?
        // The number of releases.
        var epoch = 0
    }

    private enum Next {
        case ready(Value)
        case wait(Task<Void, any Error>)
        case released
        case failed
    }

    // The loads of one take.
    static var tries: Int { 3 }

    private let state = Mutex(State())
    private let load: @Sendable (Key) async throws -> Value

    init(load: @escaping @Sendable (Key) async throws -> Value) {
        self.load = load
    }

    // The epoch now. A caller reads it at its start and gives it to take and loadNext.
    var epoch: Int { state.withLock { $0.epoch } }

    // Make the value ready: wait for the load that runs, or start one. It ends at once when the
    // value is ready.
    func prepare(_ key: Key) async throws(Failure) {
        let loading = state.withLock { s in
            s.value != nil ? nil : s.loading ?? start(&s, key)
        }
        guard let loading else { return }
        do {
            try await loading.value
        } catch {
            throw .loadFailed
        }
    }

    // Take the value: the ready one, or the one of a load. The take counts the loads that it
    // waits for, and fails when the last of them gives no value.
    func take(_ key: Key, epoch: Int) async throws(Failure) -> Value {
        var loads = 0
        while true {
            let next: Next = state.withLock { s in
                guard s.epoch == epoch else { return .released }
                if let value = s.value {
                    s.value = nil
                    return .ready(value)
                }
                guard loads < Self.tries else { return .failed }
                return .wait(s.loading ?? start(&s, key))
            }
            switch next {
            case .ready(let value): return value
            case .released: throw .released
            case .failed: throw .loadFailed
            // A failed load cleared itself, so the next pass starts a new load.
            case .wait(let loading):
                loads += 1
                _ = try? await loading.value
            }
        }
    }

    // Start the load of the next value, after a use, so the next use is quick. It does nothing
    // after a release, or when a value is ready or loads. True when a load started.
    @discardableResult
    func loadNext(_ key: Key, epoch: Int) -> Bool {
        state.withLock { s in
            guard s.epoch == epoch, s.value == nil, s.loading == nil else { return false }
            _ = start(&s, key)
            return true
        }
    }

    // The value and the load go, and a new epoch starts.
    func release() {
        state.withLock { s in
            s.value = nil
            s.loading?.cancel()
            s.loading = nil
            s.epoch += 1
        }
    }

    private func start(_ s: inout State, _ key: Key) -> Task<Void, any Error> {
        let epoch = s.epoch
        let load = load
        let task = Task { [weak self] in
            do {
                let value = try await load(key)
                self?.state.withLock { s in
                    guard s.epoch == epoch else { return }
                    s.value = value
                    s.loading = nil
                }
            } catch {
                self?.state.withLock { s in
                    if s.epoch == epoch { s.loading = nil }
                }
                throw error
            }
        }
        s.loading = task
        return task
    }
}
