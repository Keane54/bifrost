// The events of the helper on stdout: one JSON object on each line. The keys and the values are
// exactly the protocol of src/shared/dictation-protocol.ts. Bifrost refuses all other lines.
import Foundation

// Bifrost refuses a line that is longer than MAX_HELPER_LINE (UTF-16 units). The count of UTF-8
// bytes is never less than the count of UTF-16 units.
private let maxLineBytes = 64_000

// One serial queue writes all lines. So each line stays whole, the lines stay in order, and a slow
// reader never stops the audio thread.
private let outQueue = DispatchQueue(label: "com.keyholding.bifrost.dictation.out")

enum ErrorCode: String {
  // macOS shows its prompt now. The user answers the prompt.
  case micAsked = "mic-asked"
  case speechAsked = "speech-asked"
  // The user said no. The user can change it in System Settings.
  case micDenied = "mic-denied"
  case speechDenied = "speech-denied"
  case noModel = "no-model"
  case failed = "failed"
}

// A reason that the helper cannot do a command. It becomes an error event.
struct HelperError: Error {
  let code: ErrorCode
  let message: String

  // Each error that is not a HelperError is a failure.
  static func from(_ error: Error) -> HelperError {
    if let known = error as? HelperError { return known }
    return HelperError(code: .failed, message: error.localizedDescription)
  }
}

enum Out {
  static func downloading(_ progress: Double) {
    write(["t": "downloading", "progress": fraction(progress)])
  }

  static func ready(language: String, fallback: Bool) {
    write(["t": "ready", "language": language, "fallback": fallback])
  }

  static func level(_ value: Double) {
    write(["t": "level", "v": fraction(value)])
  }

  static func text(final: String, volatile: String) {
    write(["t": "text", "final": final, "volatile": volatile])
  }

  static func end(final: String) {
    write(["t": "end", "final": final])
  }

  static func error(_ error: HelperError) {
    write(["t": "error", "code": error.code.rawValue, "message": error.message])
  }

  // A note for the log of Bifrost. It goes to stderr, so it is not part of the protocol.
  static func note(_ text: String) {
    outQueue.async {
      try? FileHandle.standardError.write(contentsOf: Data("bifrost-dictation: \(text)\n".utf8))
    }
  }

  // Wait until all lines are written. Call it before exit.
  static func flush() {
    outQueue.sync {}
  }

  private static func write(_ fields: [String: Any]) {
    outQueue.async {
      guard var line = encode(fields) else { return }
      if line.count > maxLineBytes {
        let tooLong: [String: Any] = [
          "t": "error", "code": ErrorCode.failed.rawValue, "message": "The text is too long.",
        ]
        guard let replacement = encode(tooLong) else { return }
        line = replacement
      }
      line.append(0x0A)
      do {
        try FileHandle.standardOutput.write(contentsOf: line)
      } catch {
        // Bifrost closed the pipe, so nobody reads the events. Stop the helper.
        exit(0)
      }
    }
  }

  // A value from 0 to 1 with 3 decimals. A Decimal gives "0.352" in JSON, not
  // "0.35199999999999998".
  private static func fraction(_ value: Double) -> Decimal {
    let clamped = min(1, max(0, value.isNaN ? 0 : value))
    return Decimal(Int((clamped * 1000).rounded())) / 1000
  }

  private static func encode(_ fields: [String: Any]) -> Data? {
    try? JSONSerialization.data(
      withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
  }
}

extension NSLock {
  // Run the body while the lock is held. NSLocking.withLock needs macOS 14.
  func guarded<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
