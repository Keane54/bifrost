// The events that the dictation service gives to a chat window, and the error codes of a dictation
// (docs/behaviour/dictation.md, "The dictation service"). The speech engine runs in the app
// process, so no helper process and no helper protocol exist.

// The error codes that a chat window can get. macOS 26 needs no Speech Recognition permission,
// so no code is about that permission.
public enum DictationErrorCode: String, Sendable, CaseIterable {
    // macOS has no answer for the microphone yet. A start asks macOS to show its prompt and
    // gives this error at once. The user answers the prompt.
    case micAsked = "mic-asked"
    // The user said no to the microphone. The user can change it in System Settings.
    case micDenied = "mic-denied"
    // macOS cannot give an on-device speech model now.
    case noModel = "no-model"
    // The speech engine cannot start, or the recognition stopped.
    case failed
    // The speech engine is not there. A new hold cannot help then. The raw value keeps the code
    // no-helper, so its text stays the same.
    case unavailable = "no-helper"
}

// An event of the dictation service for one chat window.
package enum DictationViewEvent: Sendable, Equatable {
    // The speech model of the language is not on the Mac, and the download runs. The progress
    // goes from 0 to 1. During the download, a start opens no microphone.
    case downloading(progress: Double)
    // The speech model is loaded. fallback is true when macOS has no speech model for the system
    // language, so dictation uses English.
    case ready(language: String, fallback: Bool)
    // The voice level, 0 to 1, about 30 times a second while the microphone is open.
    case level(Double)
    // The text so far. final does not change any more. volatile can still change.
    case text(final: String, volatile: String)
    // The final text of the dictation, after a stop.
    case end(final: String)
    // The dictation could not start, or it stopped.
    case error(DictationErrorCode)
    // The download that a start got ended. That start opened no microphone. A new hold opens it.
    case modelReady
}
