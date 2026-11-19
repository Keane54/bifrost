
// The speech engine of dictation (user decision 2026-11-15: SpeechAnalyzer and SpeechTranscriber in
// the app process, macOS 26 only). AnalyzerEngine is the real engine. FakeSpeechEngine (only in a
// Debug build) drives each test and the smoke test, so no test opens the microphone.
//
// The engine opens the microphone only in begin, and each session closes it at its end, its cancel
// or its failure. The service (DictationService) begins one session at a time: the next begin waits
// for the end of the session before it.

// The answer of macOS for the microphone.
package enum SpeechPermission: Sendable, Equatable {
    case granted
    // macOS has no answer yet. ask() shows the prompt.
    case undetermined
    case denied
}

// The speech model is loaded. fallback is true when macOS has no speech model for the system
// language, so dictation uses English.
package struct SpeechReady: Sendable, Equatable {
    // The BCP 47 ID of the language of the model, for example en-US.
    package var language: String
    package var fallback: Bool

    package init(language: String, fallback: Bool) {
        self.language = language
        self.fallback = fallback
    }
}

// A failure of the engine, with the code that the chat window shows.
package enum SpeechError: Error, Sendable, Equatable {
    case code(DictationErrorCode)

    package var code: DictationErrorCode {
        switch self {
        case .code(let code): code
        }
    }
}

// An event of a session while its microphone is open.
package enum SpeechEvent: Sendable, Equatable {
    // The voice level, from 0 to 1, about 30 times a second.
    case level(Double)
    // The text so far. final does not change any more. volatile can still change.
    case text(final: String, volatile: String)
}

// One session of the engine: the microphone is open from the begin to the end, the cancel or a
// failure.
package protocol SpeechSession: AnyObject, Sendable {
    // The events of the session, in order. The stream ends at the end and at the cancel of the
    // session. It throws a SpeechError when the session fails: the session then closes the
    // microphone by itself.
    var events: AsyncThrowingStream<SpeechEvent, any Error> { get }
    // Close the microphone and give the final text. When the final text does not come in about
    // 1.5 s, the session stops and gives the text so far. It runs off the main actor: the close
    // stops the audio engine.
    @concurrent func end() async -> String
    // Close the microphone and stop the session at once. It is synchronous because a window
    // close and a quit (stopAll) must close the microphone before they go on. Each other close
    // uses end().
    func cancel()
}

package protocol SpeechEngine: AnyObject, Sendable {
    // The answer of macOS for the microphone. It never shows a prompt.
    func permission() -> SpeechPermission
    // Show the prompt of macOS for the microphone one time. It does not wait for the answer.
    func ask()
    // nil: the speech model of the language is on the Mac. Else the progress of its download
    // from Apple, from 0 to 1: 0 at once, then a value when the progress changes, at most two
    // each second. The stream ends when the download ends. A download that failed makes the
    // next prepare fail with the code no-model.
    @concurrent func modelDownload() async throws(SpeechError) -> AsyncStream<Double>?
    // Load the speech model for the next session. It is quick when the model is in memory.
    @concurrent func prepare() async throws(SpeechError) -> SpeechReady
    // Open the microphone and start a session.
    @concurrent func begin() async throws(SpeechError) -> any SpeechSession
    // The idle rule, a failure and stopAll: the speech model and the audio engine go, and a
    // begin that runs gives a failure and opens no microphone. The next prepare loads them
    // again. It is synchronous and quick: the slow work of the audio engine runs off the caller.
    func release()
    // The number of times that the microphone opened and closed, for the tests and the state of
    // the test port. With no open session, the two are equal.
    var microphoneOpens: Int { get }
    var microphoneCloses: Int { get }
}
