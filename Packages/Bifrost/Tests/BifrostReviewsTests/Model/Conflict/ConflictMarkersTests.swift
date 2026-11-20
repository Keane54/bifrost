// The conflict markers of git in a file (docs/behaviour/reviews.md, "Merging the base branch").
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private func data(_ text: String?) -> Data? { text.map { Data($0.utf8) } }

@Suite("the conflict markers", .testTimeLimit)
struct ConflictMarkersTests {
    // A text conflict has a line of 7 or more "<", ">" or "|". A lone "=======" is not one.
    @Test(arguments: [
        ("<<<<<<< ours", true),
        (String(repeating: "<", count: 10), true),
        ("=======", false),
        ("a <<<<<<< b", false),
        (">>>>>>> theirs\r\n", true),
        ("let a = 1\n<<<<<<<", true),
        ("<<<<<< six", false),
        ("||||||| base\n", true),
        ("<<<<<<<< eight\n", true),
        ("<<<<<<<x", false),
        ("<<<>>>>> mixed", false),
        ("one\n=======\ntwo\n", false),
        ("", false),
    ])
    func aLineThatStartsWithSevenMarkersCounts(text: String, found: Bool) {
        #expect(ConflictMarkers.found(in: Data(text.utf8)) == found)
    }

    // The marker lines of a merge are the "<", ">" and "|" lines and each line of exactly 7 "=".
    @Test(arguments: [
        ("=======", 1),
        ("let a = 1\n=======\r\nlet a = 2\n", 1),
        ("<<<<<<< a\nx\n=======\ny\n>>>>>>> b\n", 3),
        ("========", 0),
        ("======", 0),
        ("======= x", 0),
        (" =======", 0),
        ("", 0),
    ])
    func aLineOfSevenEqualsIsAMarkerLine(text: String, lines: Int) {
        #expect(ConflictMarkers.lines(in: Data(text.utf8)) == lines)
    }

    // A marker line counts as left only when the merge has more marker lines than the head and
    // the base each have: a heading underline or a line that the file had before stays.
    @Test(arguments: [
        ("Title\n=======\nboth\n", "Title\n=======\nfeat\n", "Title\n=======\nmain\n", false),
        ("Title\n=======\nfeat\n=======\nmain\n", "Title\n=======\nfeat\n", "Title\n", true),
        ("x\n>>>>>>> b\n", "x\n", "y\n", true),
        ("x\n>>>>>>> b\n", "x\n>>>>>>> b\n", "y\n", false),
        ("=======\n", nil, nil, true),
        ("=======\n", nil, "=======\n", false),
        ("x\n", nil, nil, false),
    ] as [(String, String?, String?, Bool)])
    func aMarkerLineCountsOnlyWhenTheMergeAddedIt(
        merged: String, head: String?, base: String?, added: Bool
    ) throws {
        let bytes = try #require(data(merged))
        #expect(ConflictMarkers.added(merged: bytes, head: data(head), base: data(base)) == added)
    }
}
