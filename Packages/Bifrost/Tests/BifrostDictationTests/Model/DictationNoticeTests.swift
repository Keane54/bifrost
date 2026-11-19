// The tests of the notice line. The cases of Speech Recognition (speech-asked, speech-denied)
// have no Swift twin: macOS 26 needs no Speech Recognition permission. The view of the line has
// its tests in the chat window tests (DictationTests, docs/behaviour/dictation.md).
import Foundation
import Testing

@testable import BifrostDictation

private let micDenied = "Bifrost can't use the microphone. Allow it in System Settings."

private func view(phase: DictationPhase = .off, notice: DictationNotice? = nil) -> DictationView {
    DictationView(phase: phase, notice: notice)
}

private func errorView(_ code: DictationErrorCode) -> DictationView {
    view(notice: .error(code))
}

private func line(_ text: String, settings: Bool = false) -> NoticeLine {
    NoticeLine(text: text, opensSettings: settings)
}

@Suite("notice line")
struct NoticeLineTests {
    @Test(
        "each error gives its friendly text",
        arguments: [
            (DictationErrorCode.micDenied, micDenied, true),
            (
                .micAsked,
                "macOS is asking if Bifrost can use the microphone. Answer it, then hold the key "
                    + "again.", false
            ),
            (
                .noModel,
                "Bifrost can't get an on-device speech model right now. Hold the key to try again "
                    + "later.", false
            ),
            (.failed, "Dictation stopped. Hold the key to try again.", false),
            (.unavailable, "Dictation isn't available in this build of Bifrost.", false),
        ])
    func errorText(code: DictationErrorCode, text: String, settings: Bool) {
        #expect(DictationNoticeText.line(errorView(code)) == line(text, settings: settings))
    }

    @Test("the message of the helper never shows")
    func noHelperMessage() {
        for code: DictationErrorCode in [.micDenied, .noModel, .failed] {
            #expect(DictationNoticeText.line(errorView(code))?.text.contains("connection") == false)
        }
    }

    @Test("the other notices give their texts")
    func otherNotices() {
        #expect(
            DictationNoticeText.line(view(notice: .vimMode))
                == line("Dictation doesn't work with Claude's vim mode yet."))
        #expect(
            DictationNoticeText.line(view(notice: .refused(.noTerminal)))
                == line(
                    "This chat window isn't connected to its session, so dictation can't start."))
        #expect(
            DictationNoticeText.line(view(notice: .language("en-US")))
                == line("Your language has no on-device speech model, so Bifrost uses English."))
        #expect(
            DictationNoticeText.line(view(notice: .modelReady))
                == line("The speech model is ready. Hold the key to dictate."))
    }

    @Test("the model download shows whole percent")
    func downloadPercent() {
        let at = { (progress: Double) in
            DictationNoticeText.line(view(phase: .downloading(progress: progress)))
        }
        #expect(at(0) == line("Getting the speech model ready… 0%"))
        #expect(at(0.426)?.text == "Getting the speech model ready… 42%")
        #expect(at(0.999)?.text == "Getting the speech model ready… 99%")
        #expect(at(1)?.text == "Getting the speech model ready… 100%")
    }

    @Test
    func downloadInPlace() {
        let older = errorView(.failed).notice
        #expect(
            DictationNoticeText.line(view(phase: .downloading(progress: 0.5), notice: older))?.text
                == "Getting the speech model ready… 50%")
        #expect(DictationNoticeText.line(view()) == nil)
        #expect(DictationNoticeText.line(view(phase: .listening)) == nil)
        #expect(DictationNoticeText.line(view(phase: .downloaded)) == nil)
    }
}

@Suite("DictationNoticeLine")
struct NoticeButtonTests {
    // The button itself is a test of the notice view. This test keeps the text of the
    // button and the line that asks for it.
    @Test("a denied permission offers Open System Settings")
    func openSettings() {
        #expect(DictationNoticeText.openSettings == "Open System Settings")
        #expect(DictationNoticeText.line(errorView(.micDenied))?.opensSettings == true)
    }
}

// New tests.
struct DictationNoticeTests {
    // Only the "no" of the user to the microphone has the System Settings button.
    @Test func onlyADeniedMicrophoneOpensSystemSettings() {
        for code in DictationErrorCode.allCases {
            let line = DictationNoticeText.line(errorView(code))
            #expect(line?.opensSettings == (code == .micDenied))
        }
        #expect(
            DictationErrorCode.allCases.map(\.rawValue).sorted() == [
                "failed", "mic-asked", "mic-denied", "no-helper", "no-model",
            ])
    }

    // A progress out of the range gives 0 % or 100 %. A value that is not a number gives 0 %.
    @Test func theDownloadPercentStaysInTheRange() {
        #expect(DictationNoticeText.download(-0.5) == "Getting the speech model ready… 0%")
        #expect(DictationNoticeText.download(1.5) == "Getting the speech model ready… 100%")
        #expect(DictationNoticeText.download(.nan) == "Getting the speech model ready… 0%")
        #expect(DictationNoticeText.download(0.57) == "Getting the speech model ready… 57%")
        #expect(DictationNoticeText.download(0.99999) == "Getting the speech model ready… 99%")
    }

    @Test func theTextOfNoNoticeIsNil() {
        #expect(DictationNoticeText.text(nil) == nil)
        #expect(DictationNoticeText.text(.error(.failed)) == DictationNoticeText.error(.failed))
    }
}
