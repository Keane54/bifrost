// The texts of the status icon of the Selected Item panel (docs/behaviour/actions.md, "The
// Selected Item panel"): the lines in order, and the kind of the icon.
import Testing

@testable import BifrostSessions

private func texts(
    error: String? = nil, notice: String? = nil, sendLine: String? = nil, sendFailed: Bool = false
) -> StatusTexts {
    StatusTexts.of(error: error, notice: notice, sendLine: sendLine, sendFailed: sendFailed)
}

@Suite("the status texts")
struct StatusTextsTests {
    @Test func noTextGivesNoLineAndNoIcon() {
        #expect(texts() == StatusTexts(lines: [], kind: nil))
    }

    @Test func aNoticeGivesTheInfoIcon() {
        #expect(texts(notice: "Done.") == StatusTexts(lines: ["Done."], kind: .info))
    }

    @Test func aSendLineThatIsNotAFailureGivesTheInfoIcon() {
        #expect(texts(sendLine: "Sending...") == StatusTexts(lines: ["Sending..."], kind: .info))
    }

    @Test func anErrorOfTheActionsGivesTheErrorIcon() {
        #expect(texts(error: "Bad.").kind == .error)
    }

    @Test func aFailedSendGivesTheErrorIcon() {
        #expect(
            texts(sendLine: "No send.", sendFailed: true)
                == StatusTexts(lines: ["No send."], kind: .error))
        // A failure with no line is not an error.
        #expect(texts(notice: "N", sendFailed: true).kind == .info)
    }

    @Test func theLinesAreTheErrorThenTheNoticeThenTheSendLine() {
        let all = texts(error: "E", notice: "N", sendLine: "S")
        #expect(all == StatusTexts(lines: ["E", "N", "S"], kind: .error))
        #expect(all.text == "E\nN\nS")
    }

    @Test func anEmptyTextIsNoLine() {
        #expect(texts(error: "", notice: "", sendLine: "") == StatusTexts(lines: [], kind: nil))
        #expect(texts(error: "", sendLine: "", sendFailed: true).kind == nil)
    }
}
