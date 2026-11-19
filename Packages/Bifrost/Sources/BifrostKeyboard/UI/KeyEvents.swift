// The KeyEvent of an NSEvent, for the key rules of the key model: the key code, the two texts, the
// modifier flags and the edge. A flags-changed event is the key down or the key up of its
// modifier key (the first condition of the key-rules gate).
import AppKit

@MainActor
extension KeyEvent {
    // A key down, a key up, or a flags-changed event of a modifier key. isComposing is true while
    // the input method has marked text in the first responder. Another event gives nil. AppKit
    // raises an exception for a read of the key code of another event, or of the characters of a
    // flags-changed event, so each case reads only its own values.
    package init?(_ event: NSEvent, isComposing: Bool) {
        switch event.type {
        case .keyDown, .keyUp:
            self.init(
                keyCode: KeyCode(rawValue: event.keyCode), characters: event.characters ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                modifiers: Modifiers(event.modifierFlags), isDown: event.type == .keyDown,
                isRepeat: event.isARepeat, isComposing: isComposing)
        case .flagsChanged:
            let keyCode = KeyCode(rawValue: event.keyCode)
            guard let modifier = keyCode.modifierKey else { return nil }
            self.init(
                keyCode: keyCode, modifiers: Modifiers(event.modifierFlags),
                isDown: Self.isDown(modifier, keyCode: keyCode, flags: event.modifierFlags),
                isComposing: isComposing)
        default:
            return nil
        }
    }

    // The device flags of the left and the right modifier keys (NX_DEVICE*KEYMASK of
    // IOLLEvent.h), by key code. Caps Lock and fn have none.
    private static let deviceFlags: [UInt16: UInt] = [
        59: 0x0001, 56: 0x0002, 60: 0x0004, 55: 0x0008, 54: 0x0010, 58: 0x0020, 61: 0x0040,
        62: 0x2000,
    ]
    private static let allDeviceFlags: UInt = 0x207F

    // True when the flags-changed event of this key is its key down. The device flags tell the
    // left and the right key apart: with both Shift keys down, the key up of one leaves the
    // Shift flag on. An event with no device flags (a synthetic event) uses the flag of the
    // modifier.
    static func isDown(
        _ modifier: ModifierKey, keyCode: KeyCode, flags: NSEvent.ModifierFlags
    ) -> Bool {
        if flags.rawValue & allDeviceFlags != 0, let device = deviceFlags[keyCode.rawValue] {
            return flags.rawValue & device != 0
        }
        return flags.contains(NSEvent.ModifierFlags(modifier))
    }
}

@MainActor
extension KeyEvent.Modifiers {
    // The modifiers of a binding in the flags of an NSEvent. Caps Lock, fn and the keypad flag
    // are not modifiers of a binding: an arrow key has the fn flag.
    package init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
    }
}

@MainActor
extension NSEvent.ModifierFlags {
    // The flag of a modifier key.
    init(_ modifier: ModifierKey) {
        switch modifier {
        case .command: self = .command
        case .shift: self = .shift
        case .option: self = .option
        case .control: self = .control
        case .capsLock: self = .capsLock
        case .function: self = .function
        }
    }

    // The flags of the modifiers of a chord, for the key equivalent of a menu item.
    package init(_ modifiers: KeyEvent.Modifiers) {
        self = []
        if modifiers.contains(.shift) { insert(.shift) }
        if modifiers.contains(.control) { insert(.control) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.command) { insert(.command) }
    }
}
