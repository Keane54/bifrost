// One finding of a review round (docs/behaviour/reviews.md, "Review rounds"): its line comment,
// its paragraph in a review text, its place text and the counts of a list.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private typealias D = ReviewData

@Suite("a finding of a review", .testTimeLimit)
struct FindingTests {
    // A finding on lines of the diff is a line comment. A finding off the diff, or on the whole
    // PR, is a paragraph of the review text: its path as code and its line, then its body.
    @Test func aFindingGivesItsCommentItsParagraphAndItsPlace() {
        let line = D.finding(.bug, line: 12, body: "In.", onDiff: true)
        #expect(
            line.comment == DraftComment(path: "src/a.swift", line: 12, side: .right, body: "In."))
        #expect(line.paragraph == "`src/a.swift` line 12: In.")
        #expect(line.placeText == "src/a.swift line 12")
        let range = D.finding(
            .minor, line: 12, side: .left, startLine: 10, body: "Range.", onDiff: true)
        #expect(
            range.comment
                == DraftComment(
                    path: "src/a.swift", line: 12, side: .left, startLine: 10, body: "Range."))
        #expect(range.paragraph == "`src/a.swift` line 12: Range.")
        #expect(range.placeText == "src/a.swift lines 10-12")
        let off = D.finding(.minor, line: 99, body: "Out.")
        #expect(off.comment == nil && off.paragraph == "`src/a.swift` line 99: Out.")
        let whole = D.finding(.minor, body: "Whole.")
        #expect(whole.comment == nil && whole.paragraph == "Whole.")
        #expect(whole.placeText == "The whole pull request")
        let tick = Finding(
            kind: .nit, place: FindingPlace(path: "a`b.swift", line: 3, side: .right),
            body: "Tick.", onDiff: false)
        #expect(tick.paragraph == "``a`b.swift`` line 3: Tick.")

        let findings = [line, range, off, whole, tick]
        #expect(findings.aboveNits)
        #expect(findings.count(.bug) == 1 && findings.count(.minor) == 3)
        #expect(findings.count(.nit) == 1)
        #expect(![tick, tick].aboveNits && ![Finding]().aboveNits)
    }
}
