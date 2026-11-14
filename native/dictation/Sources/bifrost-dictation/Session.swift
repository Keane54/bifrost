// The parts that the helper, the microphone and the recognizers share.
import AVFoundation

// The answer of macOS for a permission.
enum Permission {
  case granted
  case denied
  // macOS has no answer yet. A request shows the prompt.
  case undetermined
}

// One recognizer for the life of the helper.
protocol Recognizer: AnyObject {
  // The BCP 47 ID of the language of the model, for example en-US.
  var language: String { get }
  // True when macOS has no speech model for the system language, so the recognizer uses English.
  var fallback: Bool { get }
  // The download of the speech model, or nil when the model is on the Mac.
  func modelDownload() async throws -> ModelDownload?
  // Load the model for the next session. It is quick when the model is in memory.
  func prepare() async throws
  // The answer of macOS for the recognizer. ask() shows the prompt and does not wait.
  func permission() -> Permission
  func ask()
  // Start a session. The events get its text.
  func begin(_ events: SessionEvents) async throws -> RecognizerSession
}

// One session of a recognizer.
protocol RecognizerSession: AnyObject {
  // Give one buffer. It runs on the audio thread.
  func feed(_ buffer: AVAudioPCMBuffer)
  // End the input and give the final text.
  func end() async -> String
  // Stop the session at once. end() then returns soon.
  func cancel()
}

// A download of a speech model from Apple.
protocol ModelDownload: AnyObject {
  // 0 to 1.
  var fraction: Double { get }
  func run() async throws
}

// The text events of one session. After close() or fail(), the session gives no more events.
final class SessionEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var open = true
  private var final = ""
  private var volatile = ""
  // The helper sets it. It closes the session and the microphone after a failure.
  private var onFail: (@Sendable () -> Void)?

  // Set the action that runs one time when the session fails.
  func whenFailed(_ action: @escaping @Sendable () -> Void) {
    lock.guarded { onFail = action }
  }

  // False after close() or fail().
  var isOpen: Bool {
    lock.guarded { open }
  }

  func text(_ final: String, _ volatile: String) {
    lock.guarded {
      guard open else { return }
      self.final = final
      self.volatile = volatile
      Out.text(final: final, volatile: volatile)
    }
  }

  // Give the error, stop the events and run the action of whenFailed. So a failed session closes
  // itself and the microphone, also when no stop comes.
  func fail(_ error: HelperError) {
    let action = lock.guarded { () -> (@Sendable () -> Void)? in
      guard open else { return nil }
      Out.error(error)
      open = false
      let action = onFail
      onFail = nil
      return action
    }
    action?()
  }

  // Stop the events, and give the text so far.
  @discardableResult
  func close() -> String {
    lock.guarded {
      open = false
      onFail = nil
      return final + volatile
    }
  }
}
