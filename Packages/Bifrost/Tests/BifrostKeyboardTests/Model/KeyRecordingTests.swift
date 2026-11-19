// The state of the key recorder of Settings > Keys (docs/behaviour/keys.md, "Changing a key").
import BifrostTestSupport
import Testing

@testable import BifrostKeyboard

@Suite("the key recording")
struct KeyRecordingTests {
    // A change of the state gives true. The same state again gives false.
    @Test func setTellsOnlyAChangeOfTheState() {
        var recording = KeyRecording()
        #expect(!recording.on)
        var changes: [Bool] = []
        for on in [true, true, false, false] {
            changes.append(recording.set(on))
            #expect(recording.on == on)
        }
        #expect(changes == [true, false, true, false])
    }

    // reset ends a recording, and without a recording it does nothing.
    @Test func resetEndsARecordingAndDoesNothingWithoutOne() {
        var recording = KeyRecording()
        let withoutRecording = recording.reset()
        recording.set(true)
        let withRecording = recording.reset()
        let again = recording.reset()
        #expect([withoutRecording, withRecording, again] == [false, true, false])
        #expect(!recording.on)
    }

    // Esc, and Backspace or Delete with no modifier, end the recording. Each other key down is
    // recorded, also Tab, Enter, Space and Shift+Backspace.
    @Test func escAndAPlainBackspaceEndTheRecordingAndOtherKeysRecord() {
        #expect(KeyRecording.step(for: ev(.keydown, "Escape")) == .end)
        #expect(KeyRecording.step(for: ev(.keydown, "Escape", Mods(meta: true))) == .end)
        #expect(KeyRecording.step(for: ev(.keydown, "Backspace")) == .end)
        #expect(KeyRecording.step(for: ev(.keydown, "Delete")) == .end)
        let recorded = [
            ev(.keydown, "Backspace", Mods(shift: true)), ev(.keydown, "Delete", Mods(alt: true)),
            ev(.keydown, "Tab"), ev(.keydown, "Enter"), ev(.keydown, " "),
            ev(.keydown, "w", Mods(meta: true)), ev(.keydown, "k"),
        ]
        for event in recorded {
            #expect(KeyRecording.step(for: event) == .record, "\(event)")
        }
    }

    // A key up, a key repeat, a modifier key and a key of a composition are not a new key.
    @Test func aKeyThatIsNotANewKeyIsIgnored() {
        let ignored = [
            ev(.keyup, "k"), ev(.keydown, "k", Mods(isRepeat: true)), ev(.keydown, "Shift"),
            ev(.keydown, "k", Mods(isComposing: true)),
            ev(.keydown, "Escape", Mods(isRepeat: true)),
        ]
        for event in ignored {
            #expect(KeyRecording.step(for: event) == .ignore, "\(event)")
        }
    }
}
