import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostKeyboard

// The edge of the key rules: the KeyEvent of a real NSEvent. A key down and a key up keep the key
// code, the two texts, the modifiers of a binding and the repeat. A flags-changed event is the key
// down or the key up of its modifier key.
@Suite("The key event of an NSEvent", .tags(.window))
@MainActor
struct KeyEventsTests {
    private func key(
        _ type: NSEvent.EventType, _ code: UInt16, _ characters: String, _ ignoring: String,
        _ flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: ignoring,
                isARepeat: isRepeat, keyCode: code))
    }

    private func flagsChanged(_ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try key(.flagsChanged, code, "", "", flags)
    }

    // The slots that the key layer runs for an event: the default keys, in the other zone.
    private func slots(_ event: KeyEvent) -> [String] {
        var layer = KeyLayer(keys: .defaults)
        return layer.handle(event, zone: .other, settingsOnTop: false).effects.compactMap {
            guard case .command(let slot) = $0 else { return nil }
            return slot.description
        }
    }

    @Test func aKeyDownKeepsItsCodeTextsModifiersAndRepeat() throws {
        let event = try key(.keyDown, 46, "M", "M", [.command, .shift], isRepeat: true)
        let typed = try #require(KeyEvent(event, isComposing: false))
        #expect(
            typed
                == KeyEvent(
                    keyCode: KeyCode(rawValue: 46), characters: "M",
                    modifiers: [.command, .shift], isDown: true, isRepeat: true))
        #expect(typed.key == .text("M"))
        #expect(slots(typed) == ["send-message:mod"])
        let up = try #require(KeyEvent(try key(.keyUp, 46, "m", "m"), isComposing: true))
        #expect(!up.isDown)
        #expect(up.isComposing)
        #expect(up.modifiers.isEmpty)
    }

    // AppKit gives an arrow key the fn and keypad flags. They are not modifiers of a binding, so
    // Cmd+ArrowUp still runs Mod+ArrowUp. Caps Lock is no modifier of a binding too.
    @Test func capsLockFnAndTheKeypadFlagAreNoModifiers() throws {
        let flags: NSEvent.ModifierFlags = [.command, .function, .numericPad]
        let arrow = try key(.keyDown, 126, "\u{F700}", "\u{F700}", flags)
        let typed = try #require(KeyEvent(arrow, isComposing: false))
        #expect(typed.modifiers == .command)
        #expect(typed.key == .named(.arrowUp))
        #expect(slots(typed) == ["select-prev:mod"])
        let capsA = try key(.keyDown, 0, "A", "A", .capsLock)
        let caps = try #require(KeyEvent(capsA, isComposing: false))
        #expect(caps.modifiers.isEmpty)
    }

    @Test func controlAndCommandReadTheTextWithoutModifiers() throws {
        let controlC = try key(.keyDown, 8, "\u{3}", "c", .control)
        #expect(KeyEvent(controlC, isComposing: false)?.key == .text("c"))
        let commandOptionS = try key(.keyDown, 1, "ß", "s", [.command, .option])
        #expect(KeyEvent(commandOptionS, isComposing: false)?.key == .text("s"))
        let optionE = try key(.keyDown, 14, "", "e", .option)
        #expect(KeyEvent(optionE, isComposing: false)?.key == .dead)
        let optionO = try key(.keyDown, 31, "ø", "o", .option)
        #expect(KeyEvent(optionO, isComposing: false)?.key == .text("ø"))
    }

    @Test func aFlagsChangedEventIsTheKeyDownOrTheKeyUpOfItsModifier() throws {
        let down = try #require(KeyEvent(try flagsChanged(55, [.command]), isComposing: false))
        #expect(down == KeyEvent(keyCode: KeyCode(.command), modifiers: .command, isDown: true))
        #expect(down.key == .modifier(.command))
        let up = try #require(KeyEvent(try flagsChanged(55, []), isComposing: true))
        #expect(up == KeyEvent(keyCode: KeyCode(.command), isDown: false, isComposing: true))
        // Caps Lock and fn use their own flag.
        #expect(KeyEvent(try flagsChanged(57, .capsLock), isComposing: false)?.isDown == true)
        #expect(KeyEvent(try flagsChanged(63, []), isComposing: false)?.isDown == false)
        // A flags-changed event of a key that is not a modifier key gives no event.
        #expect(KeyEvent(try flagsChanged(0, .shift), isComposing: false) == nil)
    }

    // The device flags tell the left and the right key apart (NX_DEVICE*KEYMASK).
    @Test func theDeviceFlagsTellTheLeftAndTheRightKeyApart() throws {
        let both: NSEvent.ModifierFlags = [.shift, NSEvent.ModifierFlags(rawValue: 0x2 | 0x4)]
        #expect(KeyEvent(try flagsChanged(60, both), isComposing: false)?.isDown == true)
        // Both Shift keys are down, then the left one goes up: the Shift flag stays on.
        let rightOnly: NSEvent.ModifierFlags = [.shift, NSEvent.ModifierFlags(rawValue: 0x4)]
        #expect(KeyEvent(try flagsChanged(56, rightOnly), isComposing: false)?.isDown == false)
        // The right Command key and the right Control key.
        let rightCommand: NSEvent.ModifierFlags = [.command, NSEvent.ModifierFlags(rawValue: 0x10)]
        #expect(KeyEvent(try flagsChanged(54, rightCommand), isComposing: false)?.isDown == true)
        #expect(KeyEvent(try flagsChanged(55, rightCommand), isComposing: false)?.isDown == false)
        let rightControl: NSEvent.ModifierFlags = [
            .control, NSEvent.ModifierFlags(rawValue: 0x2000),
        ]
        #expect(KeyEvent(try flagsChanged(62, rightControl), isComposing: false)?.isDown == true)
        // A synthetic event with no device flags uses the flag of the modifier.
        #expect(KeyEvent(try flagsChanged(56, .shift), isComposing: false)?.isDown == true)
    }

    @Test func anotherEventGivesNoKeyEvent() throws {
        let mouse = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(KeyEvent(mouse, isComposing: false) == nil)
    }

    // The scenario driver types with the US keyboard of the test port. Its key codes must be the
    // key codes of the tables of the key model.
    @Test func theUSKeyboardOfTheTestPortHasTheKeyCodesOfTheCore() {
        for (id, code) in USKeyboard.keyCodes.sorted(by: { $0.key < $1.key }) {
            if let name = KeyName(rawValue: id) {
                #expect(KeyCode(name) == KeyCode(rawValue: code), "\(id)")
            } else if let modifier = USKeyboard.modifierOf[id] {
                #expect(KeyCode(rawValue: code).modifierKey != nil, "\(id) \(modifier)")
            } else if let character = id.first, id.count == 1 {
                #expect(KeyCode(us: character) == KeyCode(rawValue: code), "\(id)")
            } else {
                Issue.record("an unknown key ID \(id)")
            }
        }
    }
}
