// The cleaner of a job log of GitHub Actions. The text goes to a file for Claude, so it has no
// escape sequences and no control characters, and it has a size limit.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the CI log cleaner", .testTimeLimit)
struct CILogTests {
    @Test func escapesAndControlsGo() {
        let esc = "\u{1B}"
        let raw = "\(esc)[31;1mred\(esc)[0m ok\r\n"
            + "\(esc)]0;a title\u{7}title gone\n"
            + "\(esc)]2;another\(esc)\\second gone\n"
            + "\(esc)c two bytes\u{7} bell\u{0} nul\n"
            + "tab\there\n"
            + "a\u{9B}b\u{85}c\u{7F}d\n"
            + "\(esc)[2Kclear\n"
        let result = CILog.text(Data(raw.utf8))
        #expect(
            result.text == "red ok\ntitle gone\nsecond gone\n two bytes bell nul\ntab\there\n"
                + "abcd\nclear\n")
        #expect(!result.cut)
        let bad = CILog.text(Data([0x61, 0xFF, 0x62]))
        #expect(bad.text == "a\u{FFFD}b")
    }

    // A sequence with no end must not delete the end of the log: the error lines are there.
    @Test func aSequenceWithNoEndKeepsTheEndOfTheLog() {
        let esc = "\u{1B}"
        let link = "ok 1\n\(esc)]8;;https://x.test/a\nline 2\nerror: build failed\n"
        #expect(CILog.text(Data(link.utf8)).text == "ok 1\n\nline 2\nerror: build failed\n")
        let title = "ok 1\n\(esc)]0;title\(esc)[0m rest\nerror: build failed\n"
        #expect(CILog.text(Data(title.utf8)).text == "ok 1\n rest\nerror: build failed\n")
        // A stray ESC [ or a lone ESC keeps the line feed that comes after it.
        let stray = "a\(esc)[\nb\(esc)\nerror: build failed\n"
        #expect(CILog.text(Data(stray.utf8)).text == "a\nb\nerror: build failed\n")
        // An OSC that ends with ESC \ or BEL still goes whole.
        let ended = "x\(esc)]0;t\(esc)\\y\(esc)]0;t\u{7}z\n"
        #expect(CILog.text(Data(ended.utf8)).text == "xyz\n")
    }

    @Test func theTailStartsAtALine() {
        let line = String(repeating: "x", count: 99) + "\n"
        let log = String(repeating: line, count: 3_000)
        #expect(log.utf8.count == 300_000)
        let result = CILog.text(Data(log.utf8))
        #expect(result.cut)
        #expect(result.text.hasPrefix(CILog.cutNote))
        let kept = String(result.text.dropFirst(CILog.cutNote.count))
        #expect(kept.utf8.count <= CILog.keptBytes)
        #expect(kept.hasPrefix(String(repeating: "x", count: 99) + "\n"))
        // The tail starts at a line start, so no line is dropped: 2,000 lines of 100 bytes.
        #expect(kept.utf8.count == CILog.keptBytes)
        #expect(kept.hasSuffix("\n"))
        // A line that the cut breaks is dropped: the kept text holds whole lines only.
        #expect(kept.split(separator: "\n").allSatisfy { $0.count == 99 })
        // A log with no line break keeps whole characters, also when the cut falls in one.
        let long = String(repeating: "\u{E9}", count: 150_000)
        let flat = CILog.text(Data(long.utf8), keep: 1_001)
        #expect(flat.cut)
        let body = String(flat.text.dropFirst(CILog.cutNote.count))
        #expect(body.utf8.count <= 1_001)
        #expect(!body.isEmpty && body.allSatisfy { $0 == "\u{E9}" })
    }

    // The byte before the tail is a line break, so the tail keeps its first line.
    @Test func aTailThatStartsAtALineStartKeepsItsFirstLine() {
        let log = "aaaa\nbbbb\ncccc\n"
        let exact = CILog.text(Data(log.utf8), keep: 10)
        #expect(exact.cut)
        #expect(exact.text == CILog.cutNote + "bbbb\ncccc\n")
        // A tail that starts inside a line drops the rest of that line.
        let inside = CILog.text(Data(log.utf8), keep: 11)
        #expect(inside.text == CILog.cutNote + "bbbb\ncccc\n")
        let shorter = CILog.text(Data(log.utf8), keep: 9)
        #expect(shorter.text == CILog.cutNote + "cccc\n")
    }

    @Test func aCutLogSaysSo() {
        let long = Data(String(repeating: "a\n", count: 50).utf8)
        let cut = CILog.text(long, keep: 40)
        #expect(cut.cut)
        #expect(cut.text.hasPrefix(CILog.cutNote))
        // The note does not count in the limit.
        #expect(cut.text.utf8.count > 40)
        let whole = CILog.text(long, keep: 100)
        #expect(!whole.cut)
        #expect(whole.text == String(repeating: "a\n", count: 50))
        // A log of exactly the limit stays whole.
        let exact = CILog.text(Data(String(repeating: "b", count: 40).utf8), keep: 40)
        #expect(!exact.cut && !exact.text.hasPrefix(CILog.cutNote))
        #expect(CILog.keptBytes == 200_000)
    }
}
