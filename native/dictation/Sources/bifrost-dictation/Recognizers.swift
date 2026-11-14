// The recognizer for macOS 26: SpeechAnalyzer with SpeechTranscriber and fast results. It uses
// only models that are on the Mac. A model that is not on the Mac comes from Apple one time.
import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class AnalyzerRecognizer: Recognizer, @unchecked Sendable {
  let language: String
  let fallback: Bool
  private let locale: Locale
  // The analyzer of the next session. prepare() makes it. A session uses it one time.
  private var transcriber: SpeechTranscriber?
  private var analyzer: SpeechAnalyzer?
  private var analyzerFormat: AVAudioFormat?

  private init(locale: Locale, fallback: Bool) {
    self.locale = locale
    self.fallback = fallback
    language = locale.identifier(.bcp47)
  }

  // The system language. English only when macOS has no speech model for the system language.
  static func pick() async throws -> AnalyzerRecognizer {
    if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
      return AnalyzerRecognizer(locale: locale, fallback: false)
    }
    let english = Locale(identifier: "en-US")
    if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: english) {
      return AnalyzerRecognizer(locale: locale, fallback: true)
    }
    throw HelperError(code: .noModel, message: "macOS has no speech model for this language.")
  }

  private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [])
  }

  // installedLocales is the check. AssetInventory.status alone can be wrong.
  func modelDownload() async throws -> ModelDownload? {
    let installed = await SpeechTranscriber.installedLocales
    if installed.contains(where: { $0.identifier(.bcp47) == language }) { return nil }
    try await reserve()
    let modules = [Self.makeTranscriber(locale)]
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
    else { return nil }
    return AssetDownload(request: request)
  }

  // An app can keep only a small number of languages (maximumReservedLocales). When all are in
  // use, give back one other language of the helper first.
  private func reserve() async throws {
    let reserved = await AssetInventory.reservedLocales
    if reserved.contains(where: { $0.identifier(.bcp47) == language }) { return }
    if reserved.count >= AssetInventory.maximumReservedLocales, let other = reserved.first {
      await AssetInventory.release(reservedLocale: other)
    }
    try await AssetInventory.reserve(locale: locale)
  }

  func prepare() async throws {
    if analyzer != nil { return }
    let transcriber = Self.makeTranscriber(locale)
    // processLifetime keeps the model in memory after a session, so the next prepare is quick.
    let analyzer = SpeechAnalyzer(
      modules: [transcriber],
      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    else {
      throw HelperError(code: .failed, message: "The speech model gave no audio format.")
    }
    try await analyzer.prepareToAnalyze(in: format)
    self.transcriber = transcriber
    self.analyzer = analyzer
    analyzerFormat = format
  }

  // On macOS 26, the analyzer needs no Speech Recognition permission.
  func permission() -> Permission { .granted }
  func ask() {}

  func begin(_ events: SessionEvents) async throws -> RecognizerSession {
    try await prepare()
    guard let transcriber, let analyzer, let analyzerFormat else {
      throw HelperError(code: .failed, message: "The speech model is not loaded.")
    }
    // A session uses the analyzer one time. The next prepare makes a new one.
    self.transcriber = nil
    self.analyzer = nil
    self.analyzerFormat = nil
    let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
    let session = AnalyzerSession(analyzer: analyzer, input: input, format: analyzerFormat)
    session.setResults(
      Task {
        var final = ""
        do {
          // A final result adds to the final text and clears the text that can change.
          for try await result in transcriber.results {
            let text = String(result.text.characters)
            if result.isFinal {
              final += text
              events.text(final, "")
            } else {
              events.text(final, text)
            }
          }
        } catch {
          if !session.isEnding {
            Out.note("Speech recognition stopped: \(error.localizedDescription)")
            events.fail(HelperError(code: .failed, message: "Speech recognition stopped."))
          }
        }
        return final
      })
    do {
      try await analyzer.start(inputSequence: stream)
    } catch {
      session.cancel()
      throw HelperError(
        code: .failed, message: "Speech recognition did not start: \(error.localizedDescription)")
    }
    return session
  }
}

@available(macOS 26.0, *)
private final class AssetDownload: ModelDownload {
  private let request: AssetInstallationRequest

  init(request: AssetInstallationRequest) { self.request = request }

  var fraction: Double { request.progress.fractionCompleted }

  func run() async throws { try await request.downloadAndInstall() }
}

// One session of the analyzer. The audio thread, the results task and the helper use it.
@available(macOS 26.0, *)
private final class AnalyzerSession: RecognizerSession, @unchecked Sendable {
  private let analyzer: SpeechAnalyzer
  private let format: AVAudioFormat
  private let lock = NSLock()
  private var input: AsyncStream<AnalyzerInput>.Continuation?
  private var results: Task<String, Never>?
  private var ending = false
  // Only the audio thread uses the converter. A new input format gets a new converter.
  private var converter: AVAudioConverter?

  init(
    analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation,
    format: AVAudioFormat
  ) {
    self.analyzer = analyzer
    self.input = input
    self.format = format
  }

  // True after end() or cancel(). An error of the results is then not a failure.
  var isEnding: Bool { lock.guarded { ending } }

  func setResults(_ task: Task<String, Never>) {
    lock.guarded { results = task }
  }

  // Convert one buffer to the format of the model, and give it to the analyzer.
  func feed(_ buffer: AVAudioPCMBuffer) {
    guard let input = lock.guarded({ self.input }) else { return }
    if buffer.format == format {
      input.yield(AnalyzerInput(buffer: buffer))
      return
    }
    if converter?.inputFormat != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: format)
    }
    guard let converter else { return }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if consumed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      inputStatus.pointee = .haveData
      return buffer
    }
    if status != .error && out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
  }

  // End the input, then let the analyzer make the rest of the text final.
  func end() async -> String {
    let results = stopInput()
    do {
      try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
      Out.note("The last text did not become final: \(error.localizedDescription)")
    }
    return await results?.value ?? ""
  }

  func cancel() {
    let results = stopInput()
    results?.cancel()
    let analyzer = self.analyzer
    Task { await analyzer.cancelAndFinishNow() }
  }

  private func stopInput() -> Task<String, Never>? {
    let (input, results) = lock.guarded {
      () -> (AsyncStream<AnalyzerInput>.Continuation?, Task<String, Never>?) in
      ending = true
      let current = self.input
      self.input = nil
      return (current, self.results)
    }
    input?.finish()
    return results
  }
}
