import BifrostFoundation
import BifrostSettings
import BifrostTestSupport
import Foundation

// Helpers of the settings tests. A test gives a stored value as a JSON value. The helpers read
// it as the store reads settings.json: the JSON text, then the lenient decode. A test gives an
// edit as a closure. The helpers check it as the store checks an edit.

// The decode of a stored value, or nil when the decode refuses it (a value that is not an
// object). The store then uses the defaults and logs no key.
func storedSettings(_ value: JSONValue) -> StoredSettings? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(StoredSettings.self, from: data)
}

// The settings of a stored value, as the store loads them.
func decodedSettings(_ value: JSONValue) -> Settings {
    storedSettings(value)?.settings ?? Settings()
}

// The keys of a stored value that got their defaults, as the store logs them.
func defaultedKeys(_ value: JSONValue) -> [String] {
    storedSettings(value)?.defaulted ?? []
}

// The field of the encoded settings at one key.
func savedField(_ settings: Settings, _ key: String) -> JSONValue? {
    guard case .object(let fields)? = try? encoded(settings) else { return nil }
    return fields[key]
}

// The checked settings of one edit of the defaults, as the store checks an edit.
func edited(_ edit: (inout Settings) -> Void) throws(SettingsRefusal) -> Settings {
    var settings = Settings()
    edit(&settings)
    return try settings.validated()
}

// The reason of a refused edit of the defaults, or "ok".
// The refusal of the edit, or nil when the check passes.
func reasonOf(_ edit: (inout Settings) -> Void) -> SettingsRefusal? {
    do {
        _ = try edited(edit)
        return nil
    } catch {
        return error
    }
}
