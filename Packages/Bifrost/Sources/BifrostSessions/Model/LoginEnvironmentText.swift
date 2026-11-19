import BifrostFoundation

// The text of the one login shell of the start: the path of claude and the login env. The login
// shell runs the script, and the parser reads its output.
package enum LoginEnvironmentText {
    package static let marker = "__BIFROST_ENV__"
    package static let claudeMarker = "__BIFROST_CLAUDE__"

    // The script prints the path of claude between two claude markers, then the env between two
    // env markers. The shell can print a banner or other text outside the markers. "env -0" ends
    // each entry with a NUL, so a value can hold a line feed.
    package static let script =
        "printf '%s' '\(claudeMarker)'; command -v claude; printf '%s' '\(claudeMarker)'; "
        + "printf '%s' '\(marker)'; /usr/bin/env -0; printf '%s' '\(marker)'"

    // The path of claude between the first two claude markers: the last line, trimmed. nil when
    // a marker is missing or when the line is not an absolute path (for example an alias).
    package static func claudePath(_ stdout: String) -> String? {
        let bytes = Array(stdout.utf8)
        let mark = Array(claudeMarker.utf8)
        guard let open = firstIndex(of: mark, in: bytes, from: 0),
            let close = firstIndex(of: mark, in: bytes, from: open + mark.count)
        else { return nil }
        let text = String(decoding: bytes[(open + mark.count)..<close], as: UTF8.self)
        let last = text.trimmed().split(separator: "\n").last.map { $0.trimmed() } ?? ""
        return last.hasPrefix("/") ? last : nil
    }

    // Read the env between the first two markers. Each entry is KEY=VALUE and the key ends at the
    // first "=". An empty entry gives nothing: the output ends with a NUL. Return nil if a marker
    // is missing, if an entry has no "=" or an empty key, or if the env has no PATH. An env with
    // no PATH is not usable.
    package static func parse(_ stdout: String) -> [String: String]? {
        // The parser works on the UTF-8 bytes, so a combining character after "=" or after a
        // marker cannot change a match.
        let bytes = Array(stdout.utf8)
        let mark = Array(marker.utf8)
        guard let open = firstIndex(of: mark, in: bytes, from: 0),
            let close = firstIndex(of: mark, in: bytes, from: open + mark.count)
        else { return nil }
        var env: [String: String] = [:]
        for entry in bytes[(open + mark.count)..<close].split(separator: 0) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")),
                equals != entry.startIndex
            else { return nil }
            let key = String(decoding: entry[..<equals], as: UTF8.self)
            env[key] = String(decoding: entry[(equals + 1)...], as: UTF8.self)
        }
        return env["PATH"] == nil ? nil : env
    }

    // The index of the first copy of pattern in bytes at or after start, or nil.
    static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count, start <= bytes.count - pattern.count
        else { return nil }
        return (start...(bytes.count - pattern.count)).first { index in
            bytes[index..<(index + pattern.count)].elementsEqual(pattern)
        }
    }
}
