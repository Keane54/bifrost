import BifrostFoundation

// The dictation service of the chat windows (docs/behaviour/dictation.md, "The dictation service").
// It owns the speech engine and gives the events of each dictation to the chat that started it. Its
// state is on the main actor. The work of the engine runs off the main actor (@concurrent).
//
// The engine:
// - A warm call or a start boots the engine when it has none: the download step, then the load of
//   the model. The engine goes (release) when 5 minutes pass with no warm call or start. It never
//   goes for this rule during a model download or a dictation.
// - A boot that gives an error ends the engine. Then only a start boots it again, and a warm does
//   not. So each focus of a chat does not start a new model download. An engine-limit failure is
//   the exception: a warm boots again then.
// - A model download whose progress does not change for 2 minutes (downloadStall) ends the engine
//   with the error no-model, so the user can try again with a new hold.
// - A release makes each later result of the old boot do nothing.
// - The engine is in the app process, so no limit watches a process. Only the calls that wait for
//   the speech service of macOS have a limit (engineLimit).
//
// The dictations:
// - One dictation at a time. A start of another chat stops the dictation of the first chat.
// - The events go only to the chat that started, through its listen stream. After a start, the chat
//   gets ready (when the engine is ready), downloading, level and text. A stop ends the level and
//   text events. Then the chat gets one end with the final text of the session.
// - The engine begins a session only when it is ready. A start during the boot begins at the ready.
//   A start during a model download begins no session and opens no microphone: the chat gets the
//   progress, and model-ready at the ready, so it can tell the user to hold again. The service
//   never begins that session by itself (docs/behaviour/dictation.md, The dictation service).
// - One microphone: a begin waits for the end of the session before it, also after a key release. A
//   dictation that stops before its begin runs begins no session. Each boot has its own order of
//   sessions, so a begin that hangs in an old boot never stops a new boot. The release of the old
//   boot closed its sessions, and its late begin opens no microphone (SpeechEngine.release).
// - A begin checks the microphone first. With no answer of macOS, the engine asks for it, and the
//   chat gets mic-asked at once. The begin never waits for the answer.
// - A failure of a session or of its begin ends the dictation with the error in place of the end. A
//   failed engine gives the error failed.
// - A dictation stops after 2 minutes.
// - After its end or its error, a chat gets no more events of that dictation. A new start of the
//   same chat before the end drops that end.
@MainActor
public final class DictationService {
    // The 2-minute limit of a dictation.
    nonisolated package static let holdLimit = Duration.seconds(120)
    // The idle rule: the engine goes after 5 minutes with no warm call or start.
    nonisolated static let idleLimit = Duration.seconds(300)
    // The longest wait for a call of the engine that waits for the speech service of macOS: the
    // boot (the locale checks, the asset reservation and the load of the model) and a begin (it
    // waits for the load of the analyzer of its session). That service can stop answering, and
    // then the call never ends. When the time passes, the engine fails: the chat gets an error,
    // and the next start boots a new engine. A model download has its own limit, because it can
    // be slow and its progress changes only when data comes. The time starts again at the end of
    // the download. The end of a session has its own limit in the engine, so a stop needs no
    // limit here.
    nonisolated static let engineLimit = Duration.seconds(10)
    // The longest time with no change of the progress of a model download. Then the download
    // has stopped, and the engine fails with the error no-model.
    nonisolated static let downloadStall = Duration.seconds(120)

    private typealias Listener = AsyncStream<DictationViewEvent>.Continuation

    // One boot of the engine, from the first warm call or start to its release.
    @MainActor
    private final class Boot {
        // The engine of the boot: it loads, it downloads its model (with the last progress), or
        // it is ready.
        enum State: Equatable {
            case loading
            case downloading(progress: Double)
            case ready(SpeechReady)
        }

        var state = State.loading
        // The download step and the load of the model.
        var task: Task<Void, Never>?
        // The dictations with no end yet, in the order of their starts.
        var dictations: [Dictation] = []
        // The last step of the work of the sessions of this boot: a begin or an end. The next
        // step waits for it.
        var lane: Task<Void, Never>?

        var downloads: Bool {
            if case .downloading = state { true } else { false }
        }

        // The dictation that runs now: the last one, before its stop.
        var owner: Dictation? {
            guard let last = dictations.last, !last.stopped else { return nil }
            return last
        }
    }

    // One dictation of a chat, from its start to its end.
    @MainActor
    private final class Dictation {
        // The session ID of the chat.
        let chat: SessionID
        // True after the stop. Then the chat gets no level and no text.
        var stopped = false
        // True when the chat gets no more events of this dictation.
        var silent = false
        // True when the start got the progress of a download. No session begins for it.
        var downloadAnswer = false
        // True when its begin is in the work of the sessions.
        var begun = false
        var session: (any SpeechSession)?

        init(chat: SessionID) {
            self.chat = chat
        }
    }

    private let engine: any SpeechEngine
    private let log: any DictationLog
    private var boot: Boot?
    // True after a boot failed. Then a warm boots no engine.
    private var bootFailed = false
    // The listen of each chat: its number and the input of its stream.
    private var listeners: [SessionID: (id: Int, input: Listener)] = [:]
    private var lastListen = 0
    private let idle: TimerSlot
    // The 2-minute limit of the dictation that runs now.
    private let hold: TimerSlot
    // The engineLimit of the boot or of the begin that runs now.
    private let engineWait: TimerSlot
    // The downloadStall limit of the model download that runs now.
    private let downloadWait: TimerSlot

    // log gets one event for each failure of the engine.
    package init(
        engine: any SpeechEngine, clock: any Clock<Duration>,
        log: any DictationLog = SystemDictationLog()
    ) {
        self.engine = engine
        self.log = log
        idle = TimerSlot(clock: clock)
        hold = TimerSlot(clock: clock)
        engineWait = TimerSlot(clock: clock)
        downloadWait = TimerSlot(clock: clock)
    }

    isolated deinit {
        boot?.task?.cancel()
        for listener in listeners.values { listener.input.finish() }
    }

    // The engine of the service, for the tests.
    package var speechEngine: any SpeechEngine { engine }

    // The number of times that the engine opened and closed the microphone, for the state of
    // the test port.
    public var microphoneOpens: Int { engine.microphoneOpens }
    public var microphoneCloses: Int { engine.microphoneCloses }

    // The events of the dictations of the chat, in order. A new listen for the same chat ends the
    // stream of the last listen for it. The stream ends when its reader stops.
    package func listen(for chat: SessionID) -> AsyncStream<DictationViewEvent> {
        let (events, input) = AsyncStream<DictationViewEvent>.makeStream()
        lastListen += 1
        let id = lastListen
        listeners[chat]?.input.finish()
        listeners[chat] = (id, input)
        input.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.listenEnded(chat, id: id) }
        }
        return events
    }

    // True while a boot of the engine runs or is ready. A test checks that a call started none.
    package var isBooted: Bool { boot != nil }

    // The facts that a test waits for: the boot is ready, the last progress of a model
    // download, the last step of the work of the sessions, and the count of the timers that run
    // (each one sleeps on the clock, or its time came and it did not act yet).
    var isReady: Bool {
        if case .ready = boot?.state { true } else { false }
    }
    var downloadProgress: Double? {
        if case .downloading(let progress) = boot?.state { progress } else { nil }
    }
    var sessionWork: Task<Void, Never>? { boot?.lane }
    var runningTimers: Int { [idle, hold, engineWait, downloadWait].filter(\.isRunning).count }

    // Keep the engine ready (a focused chat with a dictation key).
    package func warm() {
        if boot == nil {
            guard !bootFailed else { return }
            startBoot()
        }
        armIdle()
    }

    // Start the dictation of a chat: the session ID of the chat.
    package func start(chat: SessionID) {
        if let owner = boot?.owner, owner.chat == chat {
            armIdle()
            return
        }
        let boot = boot ?? startBoot()
        armIdle()
        if let owner = boot.owner { stop(owner, in: boot) }
        // The new dictation owns the events of the chat. An old one of the chat gets no more.
        for old in boot.dictations where old.chat == chat { old.silent = true }
        let dictation = Dictation(chat: chat)
        boot.dictations.append(dictation)
        hold.start(after: Self.holdLimit) { [weak self] in self?.holdPassed() }
        switch boot.state {
        case .loading:
            break
        case .downloading(let progress):
            dictation.downloadAnswer = true
            give(dictation, .downloading(progress: progress))
        case .ready(let ready):
            give(dictation, .ready(language: ready.language, fallback: ready.fallback))
            begin(dictation, in: boot)
        }
    }

    // Stop the dictation of the chat. The chat then gets its end.
    package func stop(chat: SessionID) {
        guard let boot, let owner = boot.owner, owner.chat == chat else { return }
        stop(owner, in: boot)
    }

    // Stop the engine at once, with its session: a window close and a quit. No chat gets an
    // event after it.
    public func stopAll() {
        guard let boot else { return }
        for dictation in boot.dictations { dictation.silent = true }
        release(boot)
    }

    // MARK: - The engine

    @discardableResult
    private func startBoot() -> Boot {
        let boot = Boot()
        self.boot = boot
        bootFailed = false
        armEngineWait()
        boot.task = Task { [weak self] in await self?.run(boot) }
        return boot
    }

    // The boot: the download step, then the load of the model.
    private func run(_ boot: Boot) async {
        do throws(SpeechError) {
            if let download = try await engine.modelDownload() {
                for await progress in download {
                    guard self.boot === boot else { return }
                    downloading(progress, in: boot)
                }
                guard self.boot === boot else { return }
                downloadWait.stop()
                armEngineWait()
            }
            guard self.boot === boot else { return }
            let ready = try await engine.prepare()
            guard self.boot === boot else { return }
            becomeReady(ready, in: boot)
        } catch {
            guard self.boot === boot else { return }
            fail(boot, .bootFailed(error.code), error.code)
            bootFailed = true
        }
    }

    // A progress of the model download. The chat that dictates gets it, and no session begins
    // for its start. A new value starts the downloadStall limit again.
    private func downloading(_ progress: Double, in boot: Boot) {
        let state = Boot.State.downloading(progress: progress)
        if boot.state != state { armDownloadWait() }
        boot.state = state
        engineWait.stop()
        guard let owner = boot.owner else { return }
        owner.downloadAnswer = true
        give(owner, .downloading(progress: progress))
    }

    // The engine is ready. The chat that dictates gets ready, and its session begins. When its
    // start got a download, it gets model-ready, and no session begins.
    private func becomeReady(_ ready: SpeechReady, in boot: Boot) {
        boot.state = .ready(ready)
        engineWait.stop()
        guard let owner = boot.owner else { return }
        if owner.downloadAnswer {
            give(owner, .modelReady)
        } else {
            give(owner, .ready(language: ready.language, fallback: ready.fallback))
            begin(owner, in: boot)
        }
    }

    // The engine failed, and it goes. The chat that dictates gets the error. A stopped
    // dictation gets an empty end: a failure comes only before the session of a begin, so it
    // has no text.
    private func fail(_ boot: Boot, _ event: DictationLogEvent, _ code: DictationErrorCode) {
        log.record(event)
        let dictations = boot.dictations
        release(boot)
        for dictation in dictations {
            give(dictation, dictation.stopped ? .end(final: "") : .error(code))
            dictation.silent = true
        }
    }

    // The engine goes, with its timers and its sessions. Each later result of the boot does
    // nothing. The cancel of a session is synchronous, so the microphone is closed before a
    // window close and a quit go on.
    private func release(_ boot: Boot) {
        self.boot = nil
        boot.task?.cancel()
        idle.stop()
        hold.stop()
        engineWait.stop()
        downloadWait.stop()
        for dictation in boot.dictations { dictation.session?.cancel() }
        engine.release()
    }

    private func armEngineWait() {
        engineWait.start(after: Self.engineLimit) { [weak self] in
            guard let self, let boot else { return }
            if case .ready = boot.state {
                fail(boot, .noSession, .failed)
            } else {
                fail(boot, .noReady, .failed)
            }
        }
    }

    // A download that stopped fails like a failed boot: only a start boots the engine again.
    private func armDownloadWait() {
        downloadWait.start(after: Self.downloadStall) { [weak self] in
            guard let self, let boot, boot.downloads else { return }
            fail(boot, .downloadStalled, .noModel)
            bootFailed = true
        }
    }

    private func armIdle() {
        idle.start(after: Self.idleLimit) { [weak self] in
            guard let self, let boot else { return }
            if boot.downloads || !boot.dictations.isEmpty {
                armIdle()
            } else {
                release(boot)
            }
        }
    }

    private func holdPassed() {
        guard let boot, let owner = boot.owner else { return }
        stop(owner, in: boot)
    }

    // MARK: - The dictations

    // Stop a dictation: the chat gets no more level or text, and then one end.
    private func stop(_ dictation: Dictation, in boot: Boot) {
        guard !dictation.stopped else { return }
        dictation.stopped = true
        hold.stop()
        if dictation.begun {
            work(in: boot) { [weak self] in await self?.end(dictation, in: boot) }
        } else {
            // No session began, so the microphone never opened.
            finish(dictation, .end(final: ""), in: boot)
        }
    }

    // The dictation failed: the chat gets the error in place of the end, and no more events. A
    // session that failed closed the microphone by itself. Its end step still runs.
    private func failed(_ dictation: Dictation, _ code: DictationErrorCode, in boot: Boot) {
        guard self.boot === boot, !dictation.silent else { return }
        give(dictation, .error(code))
        dictation.silent = true
        stop(dictation, in: boot)
    }

    // Give the last event of a dictation. Then its work is done.
    private func finish(_ dictation: Dictation, _ event: DictationViewEvent, in boot: Boot) {
        give(dictation, event)
        dictation.silent = true
        boot.dictations.removeAll { $0 === dictation }
    }

    private func give(_ dictation: Dictation, _ event: DictationViewEvent) {
        guard !dictation.silent else { return }
        listeners[dictation.chat]?.input.yield(event)
    }

    private func listenEnded(_ chat: SessionID, id: Int) {
        if listeners[chat]?.id == id { listeners[chat] = nil }
    }

    // MARK: - The work of the sessions

    private func begin(_ dictation: Dictation, in boot: Boot) {
        dictation.begun = true
        work(in: boot) { [weak self] in await self?.open(dictation, in: boot) }
    }

    // Run a step of the work of the sessions of the boot after the step before it.
    private func work(in boot: Boot, _ step: @escaping @MainActor () async -> Void) {
        let before = boot.lane
        boot.lane = Task {
            await before?.value
            await step()
        }
    }

    // The begin step. The microphone answer comes first.
    private func open(_ dictation: Dictation, in boot: Boot) async {
        guard self.boot === boot, !dictation.stopped else { return }
        if let code = Self.refusal(engine.permission()) {
            if code == .micAsked { engine.ask() }
            failed(dictation, code, in: boot)
            return
        }
        armEngineWait()
        let session: any SpeechSession
        do throws(SpeechError) {
            session = try await engine.begin()
        } catch {
            guard self.boot === boot else { return }
            engineWait.stop()
            failed(dictation, error.code, in: boot)
            return
        }
        guard self.boot === boot else {
            // The engine went during the begin. The close stops the audio engine, so it runs off
            // the main actor.
            await close(session)
            return
        }
        engineWait.stop()
        dictation.session = session
        read(session, of: dictation, in: boot)
    }

    // The end step: the session gives its final text, and the chat gets its end.
    private func end(_ dictation: Dictation, in boot: Boot) async {
        guard self.boot === boot else { return }
        let final = await dictation.session?.end() ?? ""
        guard self.boot === boot else { return }
        finish(dictation, .end(final: final), in: boot)
    }

    // Read the events of a session until its end. After the stop, the chat gets no level and no
    // text. A failure ends the dictation with its error. The reader keeps no strong reference
    // to the service.
    private func read(_ session: any SpeechSession, of dictation: Dictation, in boot: Boot) {
        Task { [weak self] in
            do {
                for try await event in session.events where !dictation.stopped {
                    switch event {
                    case .level(let value):
                        self?.give(dictation, .level(value))
                    case .text(let final, let volatile):
                        self?.give(dictation, .text(final: final, volatile: volatile))
                    }
                }
            } catch {
                self?.failed(dictation, (error as? SpeechError)?.code ?? .failed, in: boot)
            }
        }
    }

    // The microphone answer that stops a begin, or nil when the begin can open it.
    private static func refusal(_ permission: SpeechPermission) -> DictationErrorCode? {
        switch permission {
        case .granted: nil
        case .undetermined: .micAsked
        case .denied: .micDenied
        }
    }
}

// Close a session off the main actor: the close stops the audio engine.
@concurrent private func close(_ session: any SpeechSession) async {
    session.cancel()
}
