import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

@Suite("the Daily update markup", .testTimeLimit)
struct DailyMarkupTests {
    private func boldText(_ text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                ? String(text[run.range].characters) : nil
        }
    }

    @Test func boldShowsBoldAndCopiesAsTwoStars() {
        let markdown = "**Daily update**\nDone **one** and *two*\n\n**Next**"
        let text = DailyMarkup.attributed(markdown)
        #expect(String(text.characters) == "Daily update\nDone one and *two*\n\nNext")
        #expect(boldText(text) == ["Daily update", "one", "Next"])
        #expect(DailyMarkup.markdown(text) == markdown)
    }

    @Test func aPairWithNothingBetweenIsPlainText() {
        let text = DailyMarkup.attributed("a **** b")
        #expect(boldText(text).isEmpty)
        #expect(String(text.characters) == "a **** b")
    }

    @Test func aBoldPartDoesNotSpanALine() {
        let text = DailyMarkup.attributed("**one\ntwo**")
        #expect(boldText(text).isEmpty)
    }

    @Test func copyKeepsWhiteSpaceOutsideTheStars() {
        var text = AttributedString(" word ")
        text.inlinePresentationIntent = .stronglyEmphasized
        #expect(DailyMarkup.markdown(text) == " **word** ")
    }

    @Test func aWindowsLineEndGivesNoExtraEmptyLine() {
        let text = DailyMarkup.attributed("**One**\r\ntwo\r\n")
        #expect(String(text.characters) == "One\ntwo\n")
    }
}
