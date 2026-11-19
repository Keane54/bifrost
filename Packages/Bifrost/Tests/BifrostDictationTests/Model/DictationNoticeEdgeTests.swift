import Testing

@testable import BifrostDictation

// The edges of the notice line: the rounding of the download percent, each phase with each
// notice, and the fixed texts.

private func percent(_ progress: Double) -> String {
    "Getting the speech model ready… \(Int(progress))%"
}

@Suite("the dictation notice line: edges")
struct DictationNoticeEdgeTests {
    @Test(
        "the download percent is whole and never rounds up",
        arguments: [
            (0.0, "0%"), (0.004, "0%"), (0.01, "1%"), (0.07, "7%"), (0.29, "29%"), (0.57, "57%"),
            (0.58, "58%"), (0.8, "80%"), (0.999, "99%"), (0.99999, "99%"), (1.0, "100%"),
            (-1.0, "0%"), (-0.0001, "0%"), (1.0001, "100%"), (50.0, "100%"), (.nan, "0%"),
            (.infinity, "100%"), (-.infinity, "0%"),
        ])
    func percentRounding(progress: Double, expected: String) {
        #expect(
            DictationNoticeText.download(progress) == "Getting the speech model ready… \(expected)")
    }

    private static let notices: [DictationNotice?] = [
        nil, .vimMode, .refused(.noTerminal), .language("en-US"), .modelReady,
        .error(.micDenied), .error(.micAsked), .error(.noModel), .error(.failed),
        .error(.unavailable),
    ]

    @Test(
        "a phase other than download shows the notice text",
        arguments: [DictationPhase.off, .starting, .downloaded, .listening, .stopping])
    func otherPhases(phase: DictationPhase) {
        for notice in Self.notices {
            let line = DictationNoticeText.line(DictationView(phase: phase, notice: notice))
            #expect(
                line?.text == DictationNoticeText.text(notice), "\(String(describing: notice))")
            #expect(line?.opensSettings ?? false == (notice == .error(.micDenied)))
        }
    }

    @Test("the download phase shows the percent in place of each notice")
    func downloading() {
        for notice in Self.notices {
            let line = DictationNoticeText.line(
                DictationView(phase: .downloading(progress: 0.25), notice: notice))
            #expect(line == NoticeLine(text: percent(25), opensSettings: false))
        }
    }

    @Test("the fixed texts are as designed")
    func texts() {
        #expect(DictationNoticeText.openSettings == "Open System Settings")
        #expect(
            DictationRefusal.noTerminal.message
                == "This chat window isn't connected to its session, so dictation can't start.")
        #expect(DictationNoticeText.text(nil) == nil)
        #expect(DictationNoticeText.text(.language("de-DE")) == DictationNoticeText.language)
        #expect(
            DictationNoticeText.text(.refused(.noTerminal)) == DictationRefusal.noTerminal.message)
    }
}
