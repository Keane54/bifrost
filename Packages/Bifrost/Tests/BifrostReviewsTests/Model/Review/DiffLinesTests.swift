// The lines that a diff shows (docs/behaviour/reviews.md, "Review rounds").
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the lines of a diff", .testTimeLimit)
struct DiffLinesTests {
    // The files keep their order, a binary file is marked, and each hunk gives the lines of
    // each side.
    @Test func theFilesAndTheirHunks() {
        let files = ReviewData.diff
        #expect(files.map(\.path) == ["src/a.swift", "img/logo.png"])
        #expect(files.map(\.binary) == [false, true])
        #expect(files[0].hunks == [Hunk(left: 10...13, right: 10...14)])
    }

    // A deleted file keeps its old path, a quoted name of git is read back to UTF-8, and a hunk
    // with no lines on one side has no range there.
    @Test func quotedAndDeletedPaths() {
        let text = """
            diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
            --- "a/caf\\303\\251.txt"
            +++ "b/caf\\303\\251.txt"
            @@ -1 +1,2 @@
            -x
            +y
            +z
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            --- a/gone.txt
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -a
            -b
            diff --git "a/sp ace.png" "b/sp ace.png"
            Binary files "a/sp ace.png" and "b/sp ace.png" differ
            """
        let files = DiffLines.parse(text)
        #expect(files.map(\.path) == ["caf\u{e9}.txt", "gone.txt", "sp ace.png"])
        #expect(files[0].hunks == [Hunk(left: 1...1, right: 1...2)])
        #expect(files[1].hunks == [Hunk(left: 1...2, right: nil)])
        #expect(files[2].binary)
    }

    // A comment counts only on lines of one hunk of its side; a range needs its first line in
    // the same hunk, below its line.
    @Test func aCommentMustBeOnTheLinesOfAHunk() {
        let files = ReviewData.diff
        func shows(_ line: Int, _ side: DiffSide, start: Int? = nil, path: String = "src/a.swift")
            -> Bool
        {
            DiffLines.shows(
                files,
                DraftComment(path: path, line: line, side: side, startLine: start, body: "x"))
        }
        #expect(shows(14, .right))
        #expect(!shows(14, .left))
        #expect(shows(13, .left))
        #expect(!shows(9, .right))
        #expect(shows(12, .right, start: 10))
        #expect(!shows(12, .right, start: 12))
        #expect(!shows(12, .right, start: 9))
        #expect(!shows(11, .right, path: "other.swift"))
    }
}
