// The frontmatter of the SKILL.md file of a Bifrost skill, and the group of the skill.
//
// The parse accepts a small subset of YAML: a line "---", then one "key: value" line for each
// field, then a closing line "---". Each value that the subset accepts is valid YAML, so Claude
// Code reads each value the same way. The rules (docs/behaviour/skills.md, The skill files):
// - The file has no CR. The frontmatter starts at line 1 and has a closing "---".
// - No line of the frontmatter is blank. Each line is a key of the letters a to z, "_" and "-",
//   then ":", then an optional space and value. A key occurs one time.
// - The fields disable-model-invocation, user-invocable and background are booleans: true or
//   false.
// - A double-quoted value can escape only a quote and a backslash. A single-quoted value writes
//   a quote as two quotes. No text comes after the closing quote.
// - A plain value does not start with a character that YAML reserves, and it has no ": ", no
//   " #" and no ":" at its end.
// The parse reads Unicode scalars, not Characters, so a combining mark after a quote or a colon
// does not hide that quote or colon.

// The value of one field of the frontmatter.
package enum SkillField: Sendable, Equatable {
    case text(String)
    case flag(Bool)
}

// The two groups of the skills. A skill that Claude can start itself is listed: Claude Code
// adds its description to each session. A skill of the other group starts only when the user
// calls it by name.
package enum SkillGroup: String, Sendable {
    case calledByName = "called-by-name"
    case listed
}

// One skill of the skills folder of the app.
package struct SkillInfo: Sendable, Equatable {
    package var name: String
    package var description: String
    package var group: SkillGroup

    package init(name: String, description: String, group: SkillGroup) {
        self.name = name
        self.description = description
        self.group = group
    }
}

// The reason why a SKILL.md does not parse. A line number counts from 1.
package enum SkillParseError: Error, Sendable, Equatable {
    case crlfLineEnds
    case noOpeningMarker
    case noClosingMarker
    case blankLine(Int)
    case notAKeyAndValue(Int)
    case keyTwice(String)
    case notABoolean(String)
    case escapeNotAllowed(String)
    case textAfterClosingQuote(String)
    case noClosingQuote(String)
    case reservedFirstCharacter(String)
    case needsQuotes(String)

    package var message: String {
        switch self {
        case .crlfLineEnds: "The file has CRLF line ends."
        case .noOpeningMarker: "The frontmatter does not start at line 1."
        case .noClosingMarker: "The frontmatter has no closing ---."
        case .blankLine(let line): "Line \(line) of the frontmatter is blank."
        case .notAKeyAndValue(let line): "Line \(line) is not a key and a value."
        case .keyTwice(let key): "The key \(key) occurs twice."
        case .notABoolean(let key): "The field \(key) must be true or false."
        case .escapeNotAllowed(let key): "The field \(key) has an escape that is not allowed."
        case .textAfterClosingQuote(let key): "The field \(key) has text after the closing quote."
        case .noClosingQuote(let key): "The field \(key) has no closing quote."
        case .reservedFirstCharacter(let key):
            "The plain value of \(key) starts with a reserved character."
        case .needsQuotes(let key): "The plain value of \(key) needs quotes."
        }
    }
}

package enum SkillCheck {
    // The fields whose value is true or false.
    package static let booleanFields: Set<String> = [
        "disable-model-invocation", "user-invocable", "background",
    ]

    // The starts of a plain value that YAML reserves.
    private static let reservedStarts = [
        "- ", "[", "]", "{", "}", ">", "|", "*", "&", "!", "%", "@", "#", "'", "\"", "`",
    ].map { Array($0.unicodeScalars) }

    // The fields of the frontmatter of a SKILL.md, or the first reason why it does not parse.
    package static func parse(_ text: String) -> Result<[String: SkillField], SkillParseError> {
        if text.unicodeScalars.contains("\r") { return .failure(.crlfLineEnds) }
        let all = lines(of: text)
        guard all.first == "---" else { return .failure(.noOpeningMarker) }
        guard let end = all.indices.dropFirst().first(where: { all[$0] == "---" }) else {
            return .failure(.noClosingMarker)
        }
        var fields: [String: SkillField] = [:]
        for index in 1..<end {
            let line = all[index]
            if line.unicodeScalars.allSatisfy(isWhiteSpace) {
                return .failure(.blankLine(index + 1))
            }
            guard case (let key, let raw)? = keyAndValue(line) else {
                return .failure(.notAKeyAndValue(index + 1))
            }
            if fields[key] != nil { return .failure(.keyTwice(key)) }
            switch value(of: key, raw) {
            case .success(let value): fields[key] = value
            case .failure(let reason): return .failure(reason)
            }
        }
        return .success(fields)
    }

    // The lines of a file: the text split at each LF. A LF at the end does not start one more
    // line.
    package static func lines(of text: String) -> [String] {
        var all = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(Substring($0)) }
        if all.last == "" { all.removeLast() }
        return all
    }

    // The group of a skill: true in disable-model-invocation gives called-by-name, false gives
    // listed. With no value, the skill has no group.
    package static func group(_ fields: [String: SkillField]) -> SkillGroup? {
        switch fields["disable-model-invocation"] {
        case .flag(true): .calledByName
        case .flag(false): .listed
        default: nil
        }
    }

    // The key and the text after "key: ", or nil when the line is not a key and a value. A line
    // separator or a paragraph separator in the value makes the line bad.
    private static func keyAndValue(_ line: String) -> (String, String)? {
        let scalars = line.unicodeScalars
        guard let colon = scalars.firstIndex(of: ":") else { return nil }
        let key = scalars[..<colon]
        guard !key.isEmpty, key.allSatisfy(isKeyScalar) else { return nil }
        let after = scalars[scalars.index(after: colon)...]
        guard let first = after.first else { return (String(Substring(key)), "") }
        let rest = after.dropFirst()
        guard first == " ", !rest.contains("\u{2028}"), !rest.contains("\u{2029}") else {
            return nil
        }
        return (String(Substring(key)), String(Substring(rest)))
    }

    private static func isKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || scalar == "_" || scalar == "-"
    }

    // The value of one field from the text after "key: ".
    private static func value(of key: String, _ raw: String) -> Result<SkillField, SkillParseError>
    {
        let value = trimmed(Array(raw.unicodeScalars))
        if booleanFields.contains(key) {
            switch value {
            case Array("true".unicodeScalars): return .success(.flag(true))
            case Array("false".unicodeScalars): return .success(.flag(false))
            default: return .failure(.notABoolean(key))
            }
        }
        switch value.first {
        case "\"": return doubleQuoted(key, value).map(SkillField.text)
        case "'": return singleQuoted(key, value).map(SkillField.text)
        default: break
        }
        if reservedStarts.contains(where: { value.starts(with: $0) }) {
            return .failure(.reservedFirstCharacter(key))
        }
        if value.contains(Array(": ".unicodeScalars)) || value.contains(Array(" #".unicodeScalars))
            || value.last == ":"
        {
            return .failure(.needsQuotes(key))
        }
        return .success(.text(text(value)))
    }

    // A value in double quotes. Only \" and \\ are escapes.
    private static func doubleQuoted(
        _ key: String, _ value: [Unicode.Scalar]
    ) -> Result<String, SkillParseError> {
        var result: [Unicode.Scalar] = []
        var index = 1
        while index < value.count {
            let scalar = value[index]
            if scalar == "\\" {
                guard index + 1 < value.count, value[index + 1] == "\"" || value[index + 1] == "\\"
                else { return .failure(.escapeNotAllowed(key)) }
                result.append(value[index + 1])
                index += 2
            } else if scalar == "\"" {
                guard index == value.count - 1 else { return .failure(.textAfterClosingQuote(key)) }
                return .success(text(result))
            } else {
                result.append(scalar)
                index += 1
            }
        }
        return .failure(.noClosingQuote(key))
    }

    // A value in single quotes. Two quotes are one quote.
    private static func singleQuoted(
        _ key: String, _ value: [Unicode.Scalar]
    ) -> Result<String, SkillParseError> {
        var result: [Unicode.Scalar] = []
        var index = 1
        while index < value.count {
            if value[index] == "'" {
                if index + 1 < value.count, value[index + 1] == "'" {
                    result.append("'")
                    index += 2
                } else if index == value.count - 1 {
                    return .success(text(result))
                } else {
                    return .failure(.textAfterClosingQuote(key))
                }
            } else {
                result.append(value[index])
                index += 1
            }
        }
        return .failure(.noClosingQuote(key))
    }

    // The value with no white space at its start and its end.
    private static func trimmed(_ value: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard let first = value.firstIndex(where: { !isWhiteSpace($0) }),
            let last = value.lastIndex(where: { !isWhiteSpace($0) })
        else { return [] }
        return Array(value[first...last])
    }

    // The white space that the parse removes from the ends of a value: tab, vertical tab, form
    // feed, space, no-break space, the byte order mark, each other space separator, and the line
    // ends LF, CR, line separator and paragraph separator.
    private static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\t", "\u{0B}", "\u{0C}", " ", "\u{A0}", "\u{FEFF}", "\n", "\r", "\u{2028}",
            "\u{2029}":
            true
        default:
            scalar.properties.generalCategory == .spaceSeparator
        }
    }

    private static func text(_ scalars: [Unicode.Scalar]) -> String {
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars)
        return text
    }
}
