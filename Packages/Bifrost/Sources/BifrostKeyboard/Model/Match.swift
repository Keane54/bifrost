// The match of a key event to a chord (macOS rules). A chord names the key that the user types.
// The match tries three ways, and each way has a score. The rules read Unicode scalars: a key
// types one scalar.
import Foundation

// The score of a match. Only the matches with the best score act.
package enum MatchScore: Int, Comparable, Sendable {
    // The typed key cannot name a shortcut (a key of another script, a dead key, a digit row key,
    // a symbol with Shift, a letter with Option), so the place of the key stands in.
    case position = 1
    // The typed key is the key of the chord with a Shift that the layout adds (a symbol that the
    // layout types with Shift), or the Turkish dotless i for I.
    case implicitShift
    // The typed key is the key of the chord, and the modifiers are the same.
    case direct

    package static func < (left: MatchScore, right: MatchScore) -> Bool {
        left.rawValue < right.rawValue
    }
}

extension Chord {
    // The score of a key event for this chord, or nil for no match. A key of a composition and a
    // modifier key alone never match. A named key matches only its name. A dead key matches only
    // by position.
    package func match(_ event: KeyEvent) -> MatchScore? {
        if event.isComposing { return nil }
        let typed: String
        switch event.key {
        case .modifier:
            return nil
        case .named(let name):
            return key == .named(name) && event.modifiers == modifiers ? .direct : nil
        case .dead:
            return matchByPosition(event)
        case .text(let text):
            typed = normalizedKey(text.precomposedStringWithCanonicalMapping)
        }
        let direct = keysEqual(typed, key.name)
        let implicitShift =
            direct && isOneScalar(typed) && !isSingleLetter(typed)
            && !modifiers.contains(.shift)
        if direct && modifiersMatch(event, allowImplicitShift: implicitShift) {
            return implicitShift ? .implicitShift : .direct
        }
        if typed == "ı" && key == .character("I") && !event.modifiers.contains(.option)
            && modifiersMatch(event, allowImplicitShift: false)
        {
            return .implicitShift
        }
        guard positionStandsIn(typed, event) else { return nil }
        return matchByPosition(event)
    }

    // The modifiers are the same. With an implicit Shift, the event may also have Shift.
    private func modifiersMatch(_ event: KeyEvent, allowImplicitShift: Bool) -> Bool {
        event.modifiers == modifiers
            || (allowImplicitShift && event.modifiers == modifiers.union(.shift))
    }

    // The match by the place of the key: the key of a US keyboard at that place is the key of the
    // chord, and the modifiers are the same.
    private func matchByPosition(_ event: KeyEvent) -> MatchScore? {
        guard modifiersMatch(event, allowImplicitShift: false),
            let position = event.keyCode.positionKey, keysEqual(position, key.name)
        else { return nil }
        return .position
    }
}

private func isOneScalar(_ text: String) -> Bool {
    text.unicodeScalars.count == 1
}

private func isSingleLetter(_ text: String) -> Bool {
    guard isOneScalar(text), let scalar = text.unicodeScalars.first else { return false }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
        return true
    default:
        return false
    }
}

// A letter becomes upper case, and the space character becomes "Space". The Turkish dotless i
// stays as it is. A letter whose upper case is more than one scalar (ß gives SS) stays as it is.
private func normalizedKey(_ text: String) -> String {
    if isSingleLetter(text) {
        if text == "ı" { return text }
        let upper = text.uppercased()
        return isOneScalar(upper) ? upper : text
    }
    return text == " " ? "Space" : text
}

// The Unicode ranges of the Latin script (Script_Extensions=Latin of Scripts.txt).
private let latinRanges: [ClosedRange<UInt32>] = [
    0x41...0x5A, 0x61...0x7A, 0xAA...0xAA, 0xBA...0xBA, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2B8,
    0x2E0...0x2E4, 0x1D00...0x1D25, 0x1D2C...0x1D5C, 0x1D62...0x1D65, 0x1D6B...0x1D77,
    0x1D79...0x1DBE, 0x1E00...0x1EFF, 0x2071...0x2071, 0x207F...0x207F, 0x2090...0x209C,
    0x212A...0x212B, 0x2132...0x2132, 0x214E...0x214E, 0x2160...0x2188, 0x2C60...0x2C7F,
    0xA722...0xA787, 0xA78B...0xA7FF, 0xAB30...0xAB5A, 0xAB5C...0xAB64, 0xAB66...0xAB69,
    0xFB00...0xFB06, 0xFF21...0xFF3A, 0xFF41...0xFF5A,
]

private func isLatinLetter(_ text: String) -> Bool {
    guard isOneScalar(text), let scalar = text.unicodeScalars.first else { return false }
    return latinRanges.contains { $0.contains(scalar.value) }
}

private func isASCIILetter(_ text: String) -> Bool {
    guard isOneScalar(text), let scalar = text.unicodeScalars.first else { return false }
    return scalar.isASCII && scalar.properties.isAlphabetic
}

// A printable ASCII character that is not the space.
private func isASCIIPrintable(_ text: String) -> Bool {
    guard isOneScalar(text), let scalar = text.unicodeScalars.first else { return false }
    return (0x21...0x7E).contains(scalar.value)
}

// Two letters compare without case but with accents, and with no compatibility mapping. So
// Option+0 (it types "º") does not match Option+O (row K3). Other keys must be equal.
private func keysEqual(_ left: String, _ right: String) -> Bool {
    if left == right { return true }
    guard isSingleLetter(left) && isSingleLetter(right) else { return false }
    return left.compare(right, options: [.caseInsensitive]) == .orderedSame
}

// True when the place of the key may stand in for the text that it typed (macOS rules). typed is
// the text after normalizedKey.
private func positionStandsIn(_ typed: String, _ event: KeyEvent) -> Bool {
    if !isOneScalar(typed) { return false }
    if event.keyCode.isDigitRow { return true }
    if isASCIILetter(typed) { return false }
    if isASCIIPrintable(typed) { return event.modifiers.contains(.shift) }
    if !isLatinLetter(typed) { return true }
    if event.modifiers.contains(.option) { return true }
    return !event.modifiers.isDisjoint(with: [.control, .command]) && !event.keyCode.isLetter
}
