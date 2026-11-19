import Foundation
import Testing

@testable import BifrostWindows

// The text format of the release notes: only bold and code.
@Suite("release notes inline text")
struct InlineTextTests {
    private func parts(_ text: String) -> [String] {
        InlineText.parts(text).map { part in
            switch part.kind {
            case .text: "t:\(part.text)"
            case .bold: "b:\(part.text)"
            case .code: "c:\(part.text)"
            }
        }
    }

    @Test func boldAndCodeAreParts() {
        #expect(parts("a **b** c `d` e") == ["t:a ", "b:b", "t: c ", "c:d", "t: e"])
        #expect(parts("plain") == ["t:plain"])
        #expect(parts("").isEmpty)
    }

    @Test func aMarkerWithNoEndOrNoContentStaysAsText() {
        #expect(parts("a **b") == ["t:a **b"])
        #expect(parts("a `b") == ["t:a `b"])
        #expect(parts("a **** b") == ["t:a **** b"])
        #expect(parts("a `` b") == ["t:a `` b"])
    }

    @Test func otherMarkupIsPlainText() {
        #expect(parts("[link](https://x.invalid) <b>x</b> _i_") == [
            "t:[link](https://x.invalid) <b>x</b> _i_"
        ])
    }

    @Test func theAttributedTextHasTheSameCharacters() {
        let text = InlineText.attributed("a **b** `c`")
        #expect(String(text.characters) == "a b c")
    }
}
