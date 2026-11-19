// The view of the dictation of a chat window, and the texts of its notice line ("The look" in
// docs/behaviour/dictation.md). Each error code has a text of Bifrost. The message of the speech
// engine never shows, because it can be wrong.

// The phase that the chat window shows.
package enum DictationPhase: Sendable, Equatable {
    case off, starting
    // The speech model downloads during the hold. The progress goes from 0 to 1. The microphone
    // stays closed.
    case downloading(progress: Double)
    // The download ended during the hold. The microphone stays closed until a new hold.
    case downloaded
    case listening, stopping
}

// The reason that a chat refused a start of dictation, with its text for the user.
package enum DictationRefusal: Error, Sendable, Equatable {
    // The chat window has no attach to its session, so the typed text has no place to go.
    case noTerminal

    package var message: String {
        switch self {
        case .noTerminal:
            "This chat window isn't connected to its session, so dictation can't start."
        }
    }
}

package enum DictationNotice: Sendable, Equatable {
    case vimMode
    // The chat refused the start.
    case refused(DictationRefusal)
    // The chat shows a text of Bifrost for the code.
    case error(DictationErrorCode)
    // macOS has no speech model for the system language, so dictation uses English.
    case language(String)
    // The speech model download ended during the hold. A new hold opens the microphone.
    case modelReady
}

package struct DictationView: Sendable, Equatable {
    package var phase: DictationPhase
    package var notice: DictationNotice?

    package init(phase: DictationPhase, notice: DictationNotice?) {
        self.phase = phase
        self.notice = notice
    }
}

// The line that the chat window shows.
package struct NoticeLine: Sendable, Equatable {
    package var text: String
    // True when the line has the "Open System Settings" button. It opens the Microphone pane of
    // Privacy & Security, because the prompt of macOS shows only once.
    package var opensSettings: Bool

    package init(text: String, opensSettings: Bool) {
        self.text = text
        self.opensSettings = opensSettings
    }
}

package enum DictationNoticeText {
    package static let vimMode = "Dictation doesn't work with Claude's vim mode yet."
    package static let language =
        "Your language has no on-device speech model, so Bifrost uses English."
    package static let modelReady = "The speech model is ready. Hold the key to dictate."
    package static let openSettings = "Open System Settings"

    // The text of an error code.
    package static func error(_ code: DictationErrorCode) -> String {
        switch code {
        case .failed: "Dictation stopped. Hold the key to try again."
        case .micAsked:
            "macOS is asking if Bifrost can use the microphone. Answer it, then hold the key again."
        case .micDenied: "Bifrost can't use the microphone. Allow it in System Settings."
        case .unavailable: "Dictation isn't available in this build of Bifrost."
        case .noModel:
            "Bifrost can't get an on-device speech model right now. Hold the key to try again "
                + "later."
        }
    }

    // The text of the model download. The percent is a whole number from 0 to 100. It shows 100
    // only when the download is complete. The small addition stops a rounding error, for example
    // 0.57 * 100 = 56.99999999999999. A progress that is not a number shows 0.
    package static func download(_ progress: Double) -> String {
        let value = (progress * 100 + 1e-6).rounded(.down)
        let percent = value.isNaN ? 0 : Int(min(100, max(0, value)))
        return "Getting the speech model ready… \(percent)%"
    }

    // The text of a notice, or nil for no notice.
    package static func text(_ notice: DictationNotice?) -> String? {
        switch notice {
        case .vimMode: vimMode
        case .refused(let refusal): refusal.message
        case .error(let code): error(code)
        case .language: language
        case .modelReady: modelReady
        case nil: nil
        }
    }

    // The line that the chat window shows, or nil. During a hold in the model download, the
    // line shows the progress in place of an older notice.
    package static func line(_ view: DictationView) -> NoticeLine? {
        if case .downloading(let progress) = view.phase {
            return NoticeLine(text: download(progress), opensSettings: false)
        }
        guard let text = text(view.notice) else { return nil }
        return NoticeLine(text: text, opensSettings: view.notice == .error(.micDenied))
    }
}
