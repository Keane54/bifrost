// The edge cases of the hold gate. These rules decide what reaches a session. Each case is a short
// script: the events, and the expected result of each step. The edge cases of the hold key of
// dictation are in BifrostDictationTests (HoldKeyEdgeTests), because the hold key runs on a clock.
import Testing

@testable import BifrostKeyboard

// The hold key of a letter or a digit.
private func hold(_ key: String) -> Chord {
    Chord(key: .character(Character(key)))
}

private enum GateStep: Sendable {
    case down(String, active: Bool = true)
    case up(String, gives: Bool)
    case click(gives: String?)
    case press(String, gives: String?)
    case release(String, gives: String?)
    case holding(Bool)
    case isDown(String, Bool)
    case clear
}

private struct GateCase: Sendable, CustomTestStringConvertible {
    let name: String
    let steps: [GateStep]
    var testDescription: String { name }
}

private let gateCases: [GateCase] = [
    GateCase(
        name: "a repeat keeps the state of the first down: inactive first stays inactive",
        steps: [
            .down("M", active: false), .down("M", active: true), .holding(false),
            .click(gives: nil), .up("M", gives: false),
        ]),
    GateCase(
        name: "a repeat keeps the state of the first down: active first stays active",
        steps: [
            .down("M", active: true), .down("M", active: false), .holding(true),
            .click(gives: "M"), .up("M", gives: false),
        ]),
    GateCase(
        name: "a repeat does not reset a key that a click used",
        steps: [
            .down("M"), .click(gives: "M"), .down("M"), .up("M", gives: false),
        ]),
    GateCase(
        name: "a new down after an up gives a fresh key",
        steps: [
            .down("M"), .click(gives: "M"), .up("M", gives: false), .down("M"),
            .up("M", gives: true),
        ]),
    GateCase(
        name: "a press with two active keys gives nil and removes the old claim",
        steps: [
            .down("M"), .press("S1", gives: "M"), .down("O"), .press("S2", gives: nil),
            .release("S1", gives: nil), .release("S2", gives: nil),
        ]),
    GateCase(
        name: "a release of another row removes the claim",
        steps: [
            .down("M"), .press("C", gives: "M"), .release("D", gives: nil),
            .release("C", gives: nil),
        ]),
    GateCase(
        name: "a press after a click on a used key still gives the key",
        steps: [
            .down("M"), .click(gives: "M"), .press("S1", gives: "M"), .release("S1", gives: "M"),
            .release("S1", gives: nil),
        ]),
    GateCase(
        name: "a press with no key removes the old claim",
        steps: [
            .down("M"), .press("S1", gives: "M"), .up("M", gives: false),
            .press("S2", gives: nil), .release("S1", gives: nil),
        ]),
    GateCase(
        name: "holding is false after clear, and the keys are gone",
        steps: [
            .down("M"), .holding(true), .isDown("M", true), .clear, .holding(false),
            .isDown("M", false), .up("M", gives: false),
        ]),
    GateCase(
        name: "clear removes the claim too",
        steps: [.down("M"), .press("S1", gives: "M"), .clear, .release("S1", gives: nil)]),
]

@Suite("The hold gate edge cases")
struct HoldGateEdgeTests {
    @Test("the hold gate script gives its results", arguments: gateCases)
    fileprivate func script(_ item: GateCase) {
        var gate = HoldGate()
        for step in item.steps {
            switch step {
            case .down(let key, let active): gate.down(hold(key), active: active)
            case .up(let key, let gives): #expect(gate.up(hold(key)) == gives, "\(step)")
            case .click(let gives): #expect(gate.click() == gives.map(hold), "\(step)")
            case .press(let row, let gives):
                #expect(gate.press(row) == gives.map(hold), "\(step)")
            case .release(let row, let gives):
                #expect(gate.release(row) == gives.map(hold), "\(step)")
            case .holding(let state): #expect(gate.holding() == state, "\(step)")
            case .isDown(let key, let state): #expect(gate.isDown(hold(key)) == state, "\(step)")
            case .clear: gate.clear()
            }
        }
    }
}
