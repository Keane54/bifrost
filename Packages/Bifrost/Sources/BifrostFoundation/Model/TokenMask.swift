// The token mask (docs/behaviour/panels.md, The token mask): it hides each secret in a text
// before the text goes to a log or to the screen. Each secret becomes ***.
//
// - The mask hides the known token of the caller, each time it occurs, as plain text.
// - It hides each token of a known form (TokenMask.forms).
// - It hides the value of a Bearer header. The word "Bearer" and the space after it stay, so the
//   text keeps its sense.
//
// The patterns read the code units of the text, not its Characters: a combining mark after a
// token makes one Character with the last character of the token, and then a pattern of
// Characters does not find the token. A hidden character inside a token stops a pattern, so a
// caller that shows an untrusted text removes the hidden characters before the mask (EventLog
// does).
import Foundation

package enum TokenMask {
    // The text that takes the place of a secret.
    package static let replacement = "***"

    // The known forms of a token, in the order of the mask: a GitHub token (classic and
    // fine-grained), an Anthropic key or token, an AWS access key ID and a Slack token.
    private static let forms = [
        "gh[opsu]_[A-Za-z0-9]{20,}", "github_pat_[A-Za-z0-9_]{20,}", "sk-ant-[A-Za-z0-9_-]{20,}",
        "AKIA[0-9A-Z]{16}", "xox[abpr]-[A-Za-z0-9-]{10,}",
    ].map(pattern)

    // The value of a Bearer header: 16 or more token characters, then the padding. Group 1 is
    // the word and the space after it.
    private static let bearer = pattern("(?i)(bearer\\s+)[A-Za-z0-9._~+/-]{16,}=*")

    // Each form and the Bearer value need a run of at least this many token characters.
    private static let shortestRun = 10

    // The text with each secret replaced by ***. An empty token is no token.
    package static func mask(_ text: String, token: String?) -> String {
        var out = text
        if let token, !token.isEmpty {
            out = out.replacingOccurrences(of: token, with: replacement, options: .literal)
        }
        guard hasLongRun(out) else { return out }
        for form in forms { out = replace(form, in: out, with: replacement) }
        return replace(bearer, in: out, with: "$1" + replacement)
    }

    // A pattern of the list above. Each one is fixed and the tests use each one, so a pattern
    // that does not compile is a defect of the code.
    private static func pattern(_ text: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: text)
        } catch {
            preconditionFailure("A pattern of the token mask does not compile: \(text)")
        }
    }

    private static func replace(
        _ pattern: NSRegularExpression, in text: String, with template: String
    ) -> String {
        pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // True when the text has a run of token characters that a form or a Bearer value needs. A
    // text with no such run has no secret of a known form, so the mask skips the patterns. Most
    // texts of the Event log are short, and the check reads each byte one time.
    private static func hasLongRun(_ text: String) -> Bool {
        var run = 0
        for byte in text.utf8 {
            run = isTokenByte(byte) ? run + 1 : 0
            if run >= shortestRun { return true }
        }
        return false
    }

    // A letter or a digit of ASCII, or one of . _ ~ + / -
    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        case UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "+"),
            UInt8(ascii: "/"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }
}
