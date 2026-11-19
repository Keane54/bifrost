// The real speech engine: SpeechAnalyzer with SpeechTranscriber and fast results, in the app
// process (user decision, 2026-11-15: SpeechAnalyzer only, macOS 26), with the microphone
// (Microphone.swift) and the level meter (LevelMeter.swift). It has no helper process and no
// fallback to SFSpeechRecognizer (row D13 of the dictation port).
//
// - It uses only models that are on the Mac. A model that is not on the Mac comes from Apple one
//   time (modelDownload).
// - The work runs off the main actor (@concurrent). The state is in a Mutex.
// - The model stays in memory for a short time after a session (.lingering), so the next prepare
//   is quick, and the idle release of the service frees it.
// - After the end of a session, the engine loads the analyzer of the next session, so the next
//   start is quick (Preload.swift). One load runs at a time. A release makes a load that runs do
//   nothing.
// - The engine never saves audio and never sends audio or text off the Mac.
//
// No test makes this engine: the tests use FakeSpeechEngine, so no test opens the microphone or
// downloads a speech model.
//
// The input block of AVAudioConverter is Sendable, but AVAudioPCMBuffer is not, and the block
// must give the buffer of the microphone. The block runs during the convert call, on the same
// thread. So AVFoundation is a preconcurrency import in this file only.
@preconcurrency import AVFoundation
import Foundation
import Speech
import Synchronization

package final class AnalyzerEngine: SpeechEngine {
    // The time that an end waits for the final text. After it, the end has the text so far. The
    // analyzer makes the rest of the text final in the speech service of macOS, and that service
    // can stop answering. So the end of a session never waits longer than this.
    static let endLimit = Duration.milliseconds(1500)
    // The shortest time between two progress values of a download: at most two each second.
    static let progressStep = Duration.milliseconds(500)

    // The language of the model, and true when macOS has no model for the system language, so
    // the engine uses English.
    fileprivate struct Language: Sendable {
        let locale: Locale
        let fallback: Bool

        var id: String { locale.identifier(.bcp47) }
    }

    // An analyzer that is ready for the next session. A session uses it one time.
    fileprivate struct Prepared: Sendable {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
    }

    private struct State {
        var language: Language?
        // True after a model download failed. The next prepare gives no-model.
        var downloadFailed = false
    }

    private let state = Mutex(State())
    private let microphone = Microphone()
    // The analyzer of the next session. Its epoch counts the releases.
    private let analyzers = Preload<Language, Prepared> {
        try await AnalyzerEngine.makeAnalyzer($0)
    }

    // The init makes nothing: no audio engine, no model and no call of the Speech framework.
    package init() {}

    package var microphoneOpens: Int { microphone.opens }
    package var microphoneCloses: Int { microphone.closes }

    // macOS 26 needs no Speech Recognition permission for the analyzer. Only the microphone
    // counts.
    package func permission() -> SpeechPermission { microphone.permission() }

    package func ask() { microphone.ask() }

    // installedLocales is the check. AssetInventory.status alone can be wrong.
    @concurrent package func modelDownload() async throws(SpeechError) -> AsyncStream<Double>? {
        let language = try await pick()
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == language.id }) { return nil }
        let request: AssetInstallationRequest?
        do {
            try await reserve(language)
            request = try await AssetInventory.assetInstallationRequest(
                supporting: [Self.transcriber(language.locale)])
        } catch {
            throw .code(.noModel)
        }
        guard let request else { return nil }
        let (stream, input) = AsyncStream<Double>.makeStream()
        let download = Task { [weak self] in
            // The child task gives the progress, and it ends with this task: at the end of the
            // download or at the cancel of the stream.
            async let _ = Self.report(request.progress, to: input)
            do {
                try await request.downloadAndInstall()
            } catch {
                self?.state.withLock { $0.downloadFailed = true }
            }
            input.finish()
        }
        input.onTermination = { _ in download.cancel() }
        return stream
    }

    @concurrent package func prepare() async throws(SpeechError) -> SpeechReady {
        let language = try await pick()
        let failed = state.withLock { s in
            defer { s.downloadFailed = false }
            return s.downloadFailed
        }
        if failed { throw .code(.noModel) }
        microphone.warm()
        do {
            try await analyzers.prepare(language)
        } catch {
            throw .code(.failed)
        }
        return SpeechReady(language: language.id, fallback: language.fallback)
    }

    @concurrent package func begin() async throws(SpeechError) -> any SpeechSession {
        // A release during the begin makes the begin fail before the microphone opens. The
        // microphone checks its own epoch in its lock, so a release after the last check here
        // makes no new audio engine.
        let epoch = analyzers.epoch
        let microphoneEpoch = microphone.epoch
        let language = try await pick()
        let prepared: Prepared
        do {
            prepared = try await analyzers.take(language, epoch: epoch)
        } catch {
            throw .code(.failed)
        }
        let input = try microphone.inputFormat(epoch: microphoneEpoch)
        let (stream, analyzerInput) = AsyncStream<AnalyzerInput>.makeStream()
        let session = AnalyzerSession(
            prepared: prepared, input: analyzerInput, sampleRate: input.sampleRate,
            microphone: microphone,
            finished: { [weak self] in self?.analyzers.loadNext(language, epoch: epoch) })
        session.read(prepared.transcriber)
        do {
            try await prepared.analyzer.start(inputSequence: stream)
        } catch {
            session.cancel()
            throw .code(.failed)
        }
        guard analyzers.epoch == epoch else {
            session.cancel()
            throw .code(.failed)
        }
        do {
            try microphone.open(format: input, epoch: microphoneEpoch) { buffer in
                session.feed(buffer)
            }
        } catch {
            // The session did not start, so its text goes nowhere.
            session.cancel()
            throw error
        }
        // The session can fail during the begin. Then it closes the microphone now.
        session.microphoneOpened()
        return session
    }

    // The state changes at once, and a new epoch starts: a load and a begin of the old epoch do
    // nothing more. The language is picked again at the next use, so a new language of the
    // system counts, and a failed download no longer blocks the load. The audio engine stops
    // off the caller (Microphone.release), and the model retention ends off the caller.
    package func release() {
        state.withLock { s in
            s.language = nil
            s.downloadFailed = false
        }
        analyzers.release()
        microphone.release()
        Task { await SpeechModels.endRetention() }
    }

    // MARK: - Private

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    // The system language. English only when macOS has no speech model for the system
    // language.
    private func pick() async throws(SpeechError) -> Language {
        if let known = state.withLock({ $0.language }) { return known }
        guard SpeechTranscriber.isAvailable else { throw .code(.unavailable) }
        let language: Language
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            language = Language(locale: locale, fallback: false)
        } else if let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "en-US"))
        {
            language = Language(locale: locale, fallback: true)
        } else {
            throw .code(.noModel)
        }
        state.withLock { $0.language = language }
        return language
    }

    // Give the progress of a download: its value now at once, then the last value after each
    // change, at most one value each progressStep. Key value observation gives the changes, so
    // nothing reads the progress at an interval. It ends at its cancel.
    static func report(
        _ progress: Progress, to output: AsyncStream<Double>.Continuation,
        clock: any Clock<Duration> = ContinuousClock()
    ) async {
        let (changes, input) = AsyncStream.makeStream(
            of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let observation = progress.observe(\.fractionCompleted, options: .initial) { progress, _ in
            input.yield(progress.fractionCompleted)
        }
        for await value in changes {
            output.yield(min(1, max(0, value)))
            try? await clock.sleep(for: progressStep)
        }
        observation.invalidate()
    }

    // An app can keep only a small number of languages (maximumReservedLocales). When all are in
    // use, give back one other language first.
    private func reserve(_ language: Language) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == language.id }) { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let other = reserved.first {
            await AssetInventory.release(reservedLocale: other)
        }
        try await AssetInventory.reserve(locale: language.locale)
    }

    @concurrent private static func makeAnalyzer(_ language: Language) async throws -> Prepared {
        let transcriber = transcriber(language.locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .lingering))
        guard
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber])
        else { throw SpeechError.code(.failed) }
        try await analyzer.prepareToAnalyze(in: format)
        return Prepared(transcriber: transcriber, analyzer: analyzer, format: format)
    }
}

// True for the first claim only.
private final class Once: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { done in
            defer { done = true }
            return !done
        }
    }
}

// One session of the analyzer. The drain task of the microphone, the results task and the
// service use it. Its state is in a Mutex. The levels of the microphone and the texts of the
// results go to the service through events.
private final class AnalyzerSession: SpeechSession {
    private struct State {
        var input: AsyncStream<AnalyzerInput>.Continuation?
        var results: Task<String, Never>?
        // True after end(), cancel() or a failure. An error of the results is then not a
        // failure.
        var ending = false
        // True while the microphone of this session is open.
        var microphoneOpen = false
        // True after the end of the session started the load of the next analyzer.
        var finished = false
        // Only the drain task of the microphone uses the converter. A new input format gets a
        // new converter.
        var converter: AVAudioConverter?
        var meter: LevelMeter
        // The text so far: the final and the volatile text of the last result.
        var text = ""
    }

    let events: AsyncThrowingStream<SpeechEvent, any Error>
    private let output: AsyncThrowingStream<SpeechEvent, any Error>.Continuation
    private let state: Mutex<State>
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let microphone: Microphone
    private let finished: @Sendable () -> Void

    init(
        prepared: AnalyzerEngine.Prepared, input: AsyncStream<AnalyzerInput>.Continuation,
        sampleRate: Double, microphone: Microphone, finished: @escaping @Sendable () -> Void
    ) {
        (events, output) = AsyncThrowingStream<SpeechEvent, any Error>.makeStream()
        state = Mutex(State(input: input, meter: LevelMeter(sampleRate: sampleRate)))
        analyzer = prepared.analyzer
        format = prepared.format
        self.microphone = microphone
        self.finished = finished
    }

    // Read the results: a final result adds to the final text and clears the text that can
    // change. The task gives the final text at its end.
    func read(_ transcriber: SpeechTranscriber) {
        let output = output
        let task = Task { [weak self] in
            var final = ""
            do {
                for try await result in transcriber.results {
                    let part = String(result.text.characters)
                    let volatile = result.isFinal ? "" : part
                    if result.isFinal { final += part }
                    self?.state.withLock { $0.text = final + volatile }
                    output.yield(.text(final: final, volatile: volatile))
                }
            } catch {
                self?.fail()
            }
            return final
        }
        state.withLock { $0.results = task }
    }

    // The microphone opened. A session that ended or failed during the begin closes it now.
    func microphoneOpened() {
        let ended = state.withLock { s in
            if !s.ending { s.microphoneOpen = true }
            return s.ending
        }
        if ended { microphone.close() }
    }

    // Convert one buffer to the format of the model, give it to the analyzer, and give the
    // levels. It runs on the drain task of the microphone, never on the real-time audio thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        let levels = state.withLock { s -> [Double] in
            guard let input = s.input else { return [] }
            let levels = s.meter.feed(buffer)
            if let converted = convert(buffer, &s) { input.yield(AnalyzerInput(buffer: converted)) }
            return levels
        }
        for value in levels { output.yield(.level(value)) }
    }

    // End the input with the last frames of the microphone, then let the analyzer make the rest
    // of the text final. When the final text does not come in endLimit, stop the session and give
    // the text so far. It runs off the main actor: the end of the input stops the audio engine.
    @concurrent func end() async -> String {
        let results = stopInput()
        let analyzer = analyzer
        // The final text and the end limit race. The end reads only the first result, so a
        // finalize that never ends cannot hold it. Then both tasks get a cancel: the winner is
        // done, and the loser stops.
        let (first, input) = AsyncStream<String?>.makeStream()
        let finalize = Task {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            input.yield(await results?.value ?? "")
        }
        let limit = Task {
            do {
                try await Task.sleep(for: AnalyzerEngine.endLimit)
                input.yield(nil)
            } catch {}
        }
        var race = first.makeAsyncIterator()
        let final = await race.next() ?? nil
        input.finish()
        finalize.cancel()
        limit.cancel()
        defer { finish() }
        guard let final else {
            stopAnalysis(results)
            return state.withLock { $0.text }
        }
        return final
    }

    func cancel() {
        stopAnalysis(stopInput())
        finish()
    }

    // The results failed: close the microphone, stop the analysis, and end the events with the
    // failure.
    private func fail() {
        let first = state.withLock { s in
            defer { s.ending = true }
            return !s.ending
        }
        guard first else { return }
        stopAnalysis(stopInput())
        output.finish(throwing: SpeechError.code(.failed))
    }

    private func stopAnalysis(_ results: Task<String, Never>?) {
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    // The end of the input closes the microphone of the session. The close gives the last
    // frames of the ring to feed, so the input ends after them.
    private func stopInput() -> Task<String, Never>? {
        let (results, close) = state.withLock { s in
            s.ending = true
            defer { s.microphoneOpen = false }
            return (s.results, s.microphoneOpen)
        }
        if close { microphone.close() }
        let input = state.withLock { s in
            defer { s.input = nil }
            return s.input
        }
        input?.finish()
        return results
    }

    // The session is over: its events end (after a failure, they ended already), and the
    // analyzer of the next session loads, one time.
    private func finish() {
        output.finish()
        let first = state.withLock { s in
            defer { s.finished = true }
            return !s.finished
        }
        if first { finished() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, _ s: inout State) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if s.converter?.inputFormat != buffer.format {
            s.converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter = s.converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            guard once.claim() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        return status != .error && out.frameLength > 0 ? out : nil
    }
}
