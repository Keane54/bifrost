// The fake speech engine: the tests and the smoke test use it in place of AnalyzerEngine. It
// never opens the microphone, never records or plays audio, and never downloads a speech model.
// It only counts the opens and the closes of a microphone that is not there. Only a Debug build
// has it. A development build with a test home uses it (StartPlan.fakeSpeech).
#if DEBUG
import Synchronization

// What the fake engine does.
package struct FakeSpeechScript: Sendable, Equatable {
    // The final text of the fake engine.
    package static let helperText = "Hello from the fake helper."

    // The answer of macOS for the microphone.
    package var permission: SpeechPermission
    // The progress values of a model download, or nil when the model is on the Mac.
    package var download: [Double]?
    // True when the download ends only at finishDownload(), so a test can hold the key during
    // the download and give more progress with progress(_:).
    package var holdsDownload: Bool
    // True when each prepare waits for resume(.prepare), so a test can make a slow load.
    package var holdsPrepare: Bool
    // True when each begin waits for resume(.begin), so a test can make a slow begin.
    package var holdsBegin: Bool
    // The result of a load of the model.
    package var ready: Result<SpeechReady, SpeechError>
    // The error of a begin, or nil when the begin opens the microphone.
    package var beginError: SpeechError?
    // The events that a session gives at once after its begin.
    package var events: [SpeechEvent]
    // The final text of the end of a session.
    package var final: String

    package init(
        permission: SpeechPermission = .granted, download: [Double]? = nil,
        holdsDownload: Bool = false, holdsPrepare: Bool = false, holdsBegin: Bool = false,
        ready: Result<SpeechReady, SpeechError> = .success(
            SpeechReady(language: "en-US", fallback: false)),
        beginError: SpeechError? = nil, events: [SpeechEvent] = [], final: String = ""
    ) {
        self.permission = permission
        self.download = download
        self.holdsDownload = holdsDownload
        self.holdsPrepare = holdsPrepare
        self.holdsBegin = holdsBegin
        self.ready = ready
        self.beginError = beginError
        self.events = events
        self.final = final
    }

    // The events of the fake helper: ready for en-US with no fallback. A session gives two
    // levels and two texts, and the second text has the final text. Its end has the final text.
    package static let helper = FakeSpeechScript(
        events: [
            .level(0.4), .text(final: "", volatile: "Hello from"), .level(0.7),
            .text(final: helperText, volatile: ""),
        ], final: helperText)
}

// The fake engine is one object for all the boots of the service, as the real engine is. So a
// release closes an open session, as the real engine closes its microphone.
package final class FakeSpeechEngine: SpeechEngine {
    // A call that can wait for the test (holdsPrepare and holdsBegin).
    package enum Step: Sendable {
        case prepare, begin
    }

    // The open session: its number and the input of its events.
    fileprivate struct Open {
        let id: Int
        let events: AsyncThrowingStream<SpeechEvent, any Error>.Continuation
    }

    private struct State {
        var script: FakeSpeechScript
        var opens = 0
        var closes = 0
        var asks = 0
        var prepares = 0
        // The prepares and begins that returned or failed. A test waits for them, to prove that a
        // late call did nothing.
        var preparesDone = 0
        var beginsDone = 0
        var downloads = 0
        var releases = 0
        // The begins that came while a session had the microphone open. The service never does
        // this, so each test expects 0.
        var overlaps = 0
        var lastSession = 0
        var open: Open?
        // The download that waits for finishDownload().
        var download: AsyncStream<Double>.Continuation?
        // The calls that wait for resume(_:), in order.
        var waiting: [(step: Step, wake: CheckedContinuation<Void, Never>)] = []
    }

    private let state: Mutex<State>

    package init(script: FakeSpeechScript = .helper) {
        state = Mutex(State(script: script))
    }

    // A new script for the next calls.
    package var script: FakeSpeechScript {
        get { state.withLock { $0.script } }
        set { state.withLock { $0.script = newValue } }
    }

    package var microphoneOpens: Int { state.withLock { $0.opens } }
    package var microphoneCloses: Int { state.withLock { $0.closes } }
    // True while a session has the microphone open.
    package var microphoneOpen: Bool { state.withLock { $0.open != nil } }
    package var asks: Int { state.withLock { $0.asks } }
    package var prepares: Int { state.withLock { $0.prepares } }
    package var preparesDone: Int { state.withLock { $0.preparesDone } }
    package var beginsDone: Int { state.withLock { $0.beginsDone } }
    package var downloads: Int { state.withLock { $0.downloads } }
    package var releases: Int { state.withLock { $0.releases } }
    package var overlaps: Int { state.withLock { $0.overlaps } }

    // The calls of the step that wait for resume(_:).
    package func waiting(_ step: Step) -> Int {
        state.withLock { s in s.waiting.count { $0.step == step } }
    }

    // End the oldest call of the step that waits.
    package func resume(_ step: Step) {
        let wake = state.withLock { s in
            s.waiting.firstIndex { $0.step == step }.map { s.waiting.remove(at: $0).wake }
        }
        wake?.resume()
    }

    package func permission() -> SpeechPermission {
        state.withLock { $0.script.permission }
    }

    package func ask() {
        state.withLock { $0.asks += 1 }
    }

    @concurrent package func modelDownload() async throws(SpeechError) -> AsyncStream<Double>? {
        let (values, holds) = state.withLock { s in
            s.downloads += 1
            return (s.script.download, s.script.holdsDownload)
        }
        guard let values else { return nil }
        let (stream, input) = AsyncStream<Double>.makeStream()
        for value in values { input.yield(value) }
        if holds {
            state.withLock { $0.download = input }
        } else {
            input.finish()
        }
        return stream
    }

    // One more progress of a download that waits (holdsDownload).
    package func progress(_ value: Double) {
        state.withLock { $0.download }?.yield(value)
    }

    // End a download that waits (holdsDownload).
    package func finishDownload() {
        let download = state.withLock { s in
            defer { s.download = nil }
            return s.download
        }
        download?.finish()
    }

    @concurrent package func prepare() async throws(SpeechError) -> SpeechReady {
        let holds = state.withLock { s in
            s.prepares += 1
            return s.script.holdsPrepare
        }
        defer { state.withLock { $0.preparesDone += 1 } }
        if holds { await wait(.prepare) }
        return try state.withLock { $0.script.ready }.get()
    }

    @concurrent package func begin() async throws(SpeechError) -> any SpeechSession {
        let (holds, releases) = state.withLock { ($0.script.holdsBegin, $0.releases) }
        defer { state.withLock { $0.beginsDone += 1 } }
        if holds { await wait(.begin) }
        let (events, input) = AsyncThrowingStream<SpeechEvent, any Error>.makeStream()
        let (id, script, earlier) = try state.withLock { s throws(SpeechError) in
            // A release during the begin makes the begin fail, as in the real engine.
            if s.releases != releases { throw .code(.failed) }
            if let error = s.script.beginError { throw error }
            // A second session closes the microphone of the first one, as one microphone has
            // one session. The service never does this: the count shows it.
            let earlier = close(&s)
            if earlier != nil { s.overlaps += 1 }
            s.lastSession += 1
            s.opens += 1
            s.open = Open(id: s.lastSession, events: input)
            return (s.lastSession, s.script, earlier)
        }
        earlier?.events.finish()
        for event in script.events { input.yield(event) }
        return FakeSpeechSession(engine: self, id: id, events: events, final: script.final)
    }

    // A release closes an open session, ends a download that waits and makes a begin that runs
    // fail, as the real engine closes its microphone and drops its load.
    package func release() {
        let (download, open) = state.withLock { s in
            s.releases += 1
            defer { s.download = nil }
            return (s.download, close(&s))
        }
        download?.finish()
        open?.events.finish()
    }

    // An event of the open session. With no open session, it does nothing.
    package func emit(_ event: SpeechEvent) {
        state.withLock { $0.open }?.events.yield(event)
    }

    // The open session fails: it closes the microphone by itself and gives the code.
    package func failSession(_ code: DictationErrorCode) {
        let open = state.withLock { s in close(&s) }
        open?.events.finish(throwing: SpeechError.code(code))
    }

    // Close the microphone of the session, when it is still open. True when it closed now.
    fileprivate func close(session id: Int) -> Bool {
        let open = state.withLock { s in s.open?.id == id ? close(&s) : nil }
        open?.events.finish()
        return open != nil
    }

    private func close(_ s: inout State) -> Open? {
        guard let open = s.open else { return nil }
        s.open = nil
        s.closes += 1
        return open
    }

    private func wait(_ step: Step) async {
        await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
            state.withLock { $0.waiting.append((step, wake)) }
        }
    }
}

// One session of the fake engine.
private final class FakeSpeechSession: SpeechSession {
    let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let engine: FakeSpeechEngine
    private let id: Int
    private let final: String

    init(
        engine: FakeSpeechEngine, id: Int, events: AsyncThrowingStream<SpeechEvent, any Error>,
        final: String
    ) {
        self.engine = engine
        self.id = id
        self.events = events
        self.final = final
    }

    // A session that failed, or that a newer session or a release closed, gives an empty text.
    @concurrent func end() async -> String {
        engine.close(session: id) ? final : ""
    }

    func cancel() {
        _ = engine.close(session: id)
    }
}
#endif
