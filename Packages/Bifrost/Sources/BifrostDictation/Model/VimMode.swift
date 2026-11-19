import BifrostFoundation
import Foundation

// The vim mode of Claude Code (docs/behaviour/dictation.md, Vim mode). In vim mode, a letter in
// the NORMAL mode of Claude's prompt runs as a command, and Bifrost cannot see the mode. So
// dictation stays off while Claude's settings turn vim mode on.
//
// The name of the setting is not known for each Claude version. Claude 2.1.325 has the names
// vimMode, vimModeEnabled, isVimModeEnabled and EDITOR_MODES. Older versions use editorMode "vim"
// in ~/.claude.json. Each of them counts. Only the top level of a file counts, because deeper
// objects of ~/.claude.json hold other data, for example the settings of each project.
package enum VimMode {
    // The value of one setting: a flag, a text, or another JSON value (a number, null, a list or
    // an object). An odd value never fails the decode of the file.
    private enum Value: Decodable, Equatable {
        case flag(Bool)
        case text(String)
        case other

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .flag(flag)
            } else if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .other
            }
        }

        // True for a text that is "vim" after the trim, in any case.
        var isVim: Bool {
            guard case .text(let text) = self else { return false }
            return text.trimmed().lowercased() == "vim"
        }
    }

    // The top-level keys of a settings file that can turn vim mode on, and nothing else. So the
    // decode of a large file skips the values of the other keys.
    private struct Settings: Decodable {
        private enum CodingKeys: String, CodingKey {
            case vimMode, vimModeEnabled, isVimModeEnabled, editorMode
            case editorModes = "EDITOR_MODES"
        }

        // The flags: true or the text "vim" turns vim mode on.
        var vimMode: Value?
        var vimModeEnabled: Value?
        var isVimModeEnabled: Value?
        // The modes: the text "vim" turns vim mode on.
        var editorMode: Value?
        var editorModes: Value?

        var on: Bool {
            let flags = [vimMode, vimModeEnabled, isVimModeEnabled].compactMap { $0 }
            let modes = [editorMode, editorModes].compactMap { $0 }
            return flags.contains { $0.isVim || $0 == .flag(true) }
                || modes.contains(where: \.isVim)
        }
    }

    // The vim mode of the content of a settings file. A JSON value that is not an object gives
    // false. nil when the content is no good value: not JSON (Claude can be in a write of the
    // file), or the JSON literal null. The caller then keeps the last good value of the file.
    package static func of(_ content: Data) -> Bool? {
        do {
            return try JSONDecoder().decode(Settings.self, from: content).on
        } catch DecodingError.typeMismatch(_, let context) where context.codingPath.isEmpty {
            return false
        } catch {
            return nil
        }
    }
}
