// The recognizer for macOS 13 to 15: SFSpeechRecognizer with on-device recognition only.
// It has no final part during a session. All the text can change until the end.
import AVFoundation
import Foundation
import Speech

final class SFRecognizer: Recognizer, @unchecked Sendable {
  let language: String
  let fallback: Bool
  private let recognizer: SFSpeechRecognizer
  private var askedForAccess = false

  private init(recognizer: SFSpeechRecognizer, fallback: Bool) {
    self.recognizer = recognizer
    self.fallback = fallback
    language = recognizer.locale.identifier(.bcp47)
  }

  // The system language. English only when the system language has no on-device model.
  static func pick() throws -> SFRecognizer {
    if let recognizer = SFSpeechRecognizer(locale: systemLanguage()),
      recognizer.supportsOnDeviceRecognition
    {
      return SFRecognizer(recognizer: recognizer, fallback: false)
    }
    if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
      recognizer.supportsOnDeviceRecognition
    {
      return SFRecognizer(recognizer: recognizer, fallback: true)
    }
    throw HelperError(code: .noModel, message: "macOS has no speech model on this Mac.")
  }

  // The language and the region of the system language. en_US@rg=gbzzzz gives en-US.
  private static func systemLanguage() -> Locale {
    let language = Locale.current.language
    guard let code = language.languageCode?.identifier else { return Locale(identifier: "en-US") }
    guard let region = language.region?.identifier else { return Locale(identifier: code) }
    return Locale(identifier: "\(code)-\(region)")
  }

  // macOS keeps the on-device models of SFSpeechRecognizer. The helper downloads none.
  func modelDownload() async throws -> ModelDownload? { nil }

  // The recognizer loads its model at the start of each task.
  func prepare() async throws {}

  func permission() -> Permission {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: return .granted
    case .notDetermined: return .undetermined
    default: return .denied
    }
  }

  // Show the prompt one time. Do not wait for the answer.
  func ask() {
    guard !askedForAccess else { return }
    askedForAccess = true
    SFSpeechRecognizer.requestAuthorization { _ in }
  }

  func begin(_ events: SessionEvents) async throws -> RecognizerSession {
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    request.addsPunctuation = true
    request.taskHint = .dictation
    let session = SFSession(request: request)
    session.task = recognizer.recognitionTask(with: request) { result, error in
      if let result {
        let text = result.bestTranscription.formattedString
        session.update(text)
        events.text("", text)
        if result.isFinal { session.finish() }
      }
      if let error {
        // An error after the end of the input is normal, for example "no speech".
        if !session.isEnding {
          Out.note("Speech recognition stopped: \(error.localizedDescription)")
          events.fail(HelperError(code: .failed, message: "Speech recognition stopped."))
        }
        session.finish()
      }
    }
    return session
  }
}

// One session of SFSpeechRecognizer. The callbacks of the task, the audio thread and the helper
// use it.
private final class SFSession: RecognizerSession, @unchecked Sendable {
  private let request: SFSpeechAudioBufferRecognitionRequest
  var task: SFSpeechRecognitionTask?
  private let lock = NSLock()
  private var text = ""
  private var ending = false
  private var finished = false
  private var waiter: CheckedContinuation<Void, Never>?

  init(request: SFSpeechAudioBufferRecognitionRequest) {
    self.request = request
  }

  var isEnding: Bool { lock.guarded { ending } }

  func update(_ newText: String) {
    lock.guarded { text = newText }
  }

  func feed(_ buffer: AVAudioPCMBuffer) {
    guard !isEnding else { return }
    request.append(buffer)
  }

  // End the input and wait for the last result. The helper limits the wait.
  func end() async -> String {
    lock.guarded { ending = true }
    request.endAudio()
    await waitForEnd()
    return lock.guarded { text }
  }

  func cancel() {
    lock.guarded { ending = true }
    task?.cancel()
    finish()
  }

  func finish() {
    let waiter = lock.guarded { () -> CheckedContinuation<Void, Never>? in
      finished = true
      let current = self.waiter
      self.waiter = nil
      return current
    }
    waiter?.resume()
  }

  private func waitForEnd() async {
    await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
      let done = lock.guarded { () -> Bool in
        if finished { return true }
        self.waiter = waiter
        return false
      }
      if done { waiter.resume() }
    }
  }
}
