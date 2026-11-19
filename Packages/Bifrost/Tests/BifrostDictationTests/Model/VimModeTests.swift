// The vim mode rule on the content of a settings file. The tests of the check with its stamp
// cache are in VimModeReaderTests.swift.
import Foundation
import Testing

@testable import BifrostDictation

// The vim mode of a JSON text.
private func vim(_ json: String) -> Bool? {
    VimMode.of(Data(json.utf8))
}

@Suite("vim mode value")
struct VimModeTests {
    @Test(
        "each key and value that turns vim mode on",
        arguments: [
            #"{"vimMode": true}"#, #"{"vimModeEnabled": true}"#, #"{"isVimModeEnabled": true}"#,
            #"{"vimMode": "vim"}"#, #"{"editorMode": "vim"}"#, #"{"editorMode": "Vim "}"#,
            #"{"EDITOR_MODES": "vim"}"#, #"{"theme": "dark", "editorMode": "vim", "n": [1, {}]}"#,
        ])
    func counts(_ json: String) {
        #expect(vim(json) == true)
    }

    // Other values, odd values and deeper keys give false. They never fail the decode.
    @Test(
        arguments: [
            "{}", #"{"vimMode": false}"#, #"{"vimModeEnabled": "false"}"#,
            #"{"editorMode": "normal"}"#, #"{"EDITOR_MODES": ["normal", "vim"]}"#,
            #"{"projects": {"/a": {"vimMode": true}}}"#, #"{"vimMode": 1}"#,
            #"{"vimMode": null}"#, #"{"editorMode": true}"#, #"{"editorMode": "vi"}"#,
            #"{"editorMode": {"vim": true}}"#,
        ])
    func doesNotCount(_ json: String) {
        #expect(vim(json) == false)
    }

    // A JSON value that is not an object gives false. Text that is not JSON, and the literal
    // null, are no good value: the reader keeps the last good value of the file.
    @Test func aContentThatIsNotAnObject() {
        #expect(vim(#""vim""#) == false)
        #expect(vim(#"[{"vimMode": true}]"#) == false)
        #expect(vim("12") == false)
        #expect(vim("null") == nil)
        #expect(vim(#"{"vimMode": tr"#) == nil)
        #expect(vim("") == nil)
    }

    // The trim removes white space (TextRuleTests), and the case does not count.
    @Test func theTrimAndTheCaseOfTheMode() {
        #expect(vim(#"{"editorMode": "\u0085\t VIM\n　"}"#) == true)
        #expect(vim(#"{"isVimModeEnabled": " vIm"}"#) == true)
        #expect(vim(#"{"editorMode": "v im"}"#) == false)
        #expect(vim(#"{"editorMode": "​vim"}"#) == false)
    }
}
