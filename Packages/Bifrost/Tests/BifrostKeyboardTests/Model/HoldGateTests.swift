// The hold gate of the hold keys (docs/behaviour/keys.md, "Hold keys"). HoldGate is a value, so
// each test has a var.
import Testing

@testable import BifrostKeyboard

// The hold key of a letter or a digit.
private func key(_ character: Character) -> Chord {
    Chord(key: .character(character))
}

@Suite("hold gate")
struct HoldGateTests {
    @Test
    func clickThenUp() {
        var gate = HoldGate()
        gate.down(key("O"), active: true)
        #expect(gate.click() == key("O"))
        #expect(gate.up(key("O")) == false)
    }

    @Test
    func upWithoutClick() {
        var gate = HoldGate()
        gate.down(key("O"), active: true)
        #expect(gate.isDown(key("O")) == true)
        #expect(gate.up(key("O")) == true)
        #expect(gate.isDown(key("O")) == false)
    }

    @Test
    func upNotDown() {
        var gate = HoldGate()
        #expect(gate.up(key("O")) == false)
    }

    @Test
    func repeatKeepsUsed() {
        var gate = HoldGate()
        gate.down(key("O"), active: true)
        _ = gate.click()
        gate.down(key("O"), active: true)
        #expect(gate.up(key("O")) == false)
    }

    @Test("two clicks with the same key both give that key")
    func twoClicks() {
        var gate = HoldGate()
        gate.down(key("3"), active: true)
        #expect(gate.click() == key("3"))
        #expect(gate.click() == key("3"))
    }

    @Test("two keys held together give no hold click")
    func twoKeys() {
        var gate = HoldGate()
        gate.down(key("O"), active: true)
        gate.down(key("M"), active: true)
        #expect(gate.click() == nil)
        #expect(gate.up(key("O")) == true)
        #expect(gate.up(key("M")) == true)
    }

    @Test("with no key there is no hold click")
    func noKey() {
        var gate = HoldGate()
        #expect(gate.click() == nil)
    }

    @Test("a key from a chat window or text box is not a hold key")
    func inactive() {
        var gate = HoldGate()
        gate.down(key("O"), active: false)
        #expect(gate.click() == nil)
        #expect(gate.up(key("O")) == false)
    }

    @Test("an inactive key is not a second key")
    func inactiveSecond() {
        var gate = HoldGate()
        gate.down(key("O"), active: true)
        gate.down(key("M"), active: false)
        #expect(gate.click() == key("O"))
    }

    @Test("holding stays true while one active key is down, also after a click")
    func holdingOne() {
        var gate = HoldGate()
        #expect(gate.holding() == false)
        gate.down(key("O"), active: true)
        #expect(gate.holding() == true)
        _ = gate.click()
        #expect(gate.holding() == true)
        _ = gate.up(key("O"))
        #expect(gate.holding() == false)
    }

    @Test("holding is false for an inactive key or for two active keys")
    func holdingFalse() {
        var gate = HoldGate()
        gate.down(key("O"), active: false)
        #expect(gate.holding() == false)
        gate.down(key("M"), active: true)
        #expect(gate.holding() == true)
        gate.down(key("X"), active: true)
        #expect(gate.holding() == false)
    }

    @Test
    func quickHoldClick() {
        // Final review Important 2: the key up comes before the mouse up. The key up must not act
        // on the selected row, and the click must act on the pressed row.
        var gate = HoldGate()
        gate.down(key("X"), active: true)
        #expect(gate.press("C") == key("X"))
        #expect(gate.up(key("X")) == false)
        #expect(gate.release("C") == key("X"))
    }

    @Test("a press without a hold key is a plain click")
    func plainPress() {
        var gate = HoldGate()
        #expect(gate.press("C") == nil)
        #expect(gate.release("C") == nil)
        gate.down(key("O"), active: false)
        #expect(gate.press("C") == nil)
        #expect(gate.release("C") == nil)
    }

    @Test
    func claimOneRow() {
        var gate = HoldGate()
        gate.down(key("O"), active: true)
        _ = gate.press("C")
        #expect(gate.release("D") == nil)
        _ = gate.press("C")
        #expect(gate.release("C") == key("O"))
        #expect(gate.release("C") == nil)
    }

    @Test
    func newPressRemovesClaim() {
        var gate = HoldGate()
        gate.down(key("O"), active: true)
        _ = gate.press("C")
        _ = gate.up(key("O"))
        #expect(gate.press("D") == nil)
        #expect(gate.release("C") == nil)
        #expect(gate.release("D") == nil)
    }

    @Test("clearing removes the claim")
    func clearClaim() {
        var gate = HoldGate()
        gate.down(key("O"), active: true)
        _ = gate.press("C")
        gate.clear()
        #expect(gate.release("C") == nil)
    }

    @Test("clearing forgets all keys")
    func clearKeys() {
        var gate = HoldGate()
        gate.down(key("O"), active: true)
        gate.clear()
        #expect(gate.isDown(key("O")) == false)
        #expect(gate.click() == nil)
        #expect(gate.up(key("O")) == false)
    }
}
