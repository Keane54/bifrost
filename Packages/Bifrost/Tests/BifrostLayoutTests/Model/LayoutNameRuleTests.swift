import BifrostTestSupport
import Testing

@testable import BifrostLayout

// The text rules (TextRules.swift of BifrostFoundation) in the names of the saved layouts: white
// space is Character.isWhitespace, and the limit counts Characters.

private let empty = LayoutSnapshot(frames: [], memory: [:])

@Suite("the text rules of the layout names")
struct LayoutNameRuleTests {
    @Test("a layout name reads white space as Character.isWhitespace", arguments: spaceCases)
    func whiteSpace(_ item: SpaceCase) {
        let c = item.text
        let kept = item.isSpace ? "ab" : "\(c)ab\(c)"
        var state = UIState()
        #expect(state.saveLayout("\(c)ab\(c)", empty) == .saved)
        #expect(state.layouts.map(\.name) == [kept])
    }

    @Test("the name limit counts Characters", arguments: limitUnits)
    func limits(_ unit: String) {
        func text(_ count: Int) -> String { String(repeating: unit, count: count) }
        var state = UIState()
        #expect(state.saveLayout(text(UIState.maxName), empty) == .saved)
        #expect(state.saveLayout(text(UIState.maxName + 1), empty) == .badName)
    }
}
