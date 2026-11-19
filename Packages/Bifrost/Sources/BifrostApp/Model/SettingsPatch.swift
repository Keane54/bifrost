// The change of the settings from the debug test port ({"op":"setting","patch":{...}}). Each
// field of the patch is a top-level field of settings.json with its new value, in the form of the
// file. The check is strict: the first bad field, in the order of the field names, refuses the
// whole patch, and nothing changes.
// - A field must be a field of the settings (Settings.Key) other than "version".
// - "keys" is a key edit (KeyEdit): an object of slot IDs, each with null (Off) or a binding text.
//   The edit keeps each other entry, and it refuses a new conflict with the text of the key edit:
//   "Two actions can't share the same key."
// - Each other field must keep its value at the load of settings.json. A value that the load
//   replaces with the default, or of which it keeps only a part, is refused.
// The shell applies a patch in one edit of the settings store. So the edit acts on the newest
// settings, and the store checks the result too (Settings.validated()). Only a Debug build has
// this code.
#if DEBUG
import BifrostFoundation
import BifrostKeyboard
import BifrostSettings
import Foundation

// Why the test port cannot change the settings. message is the error text of the answer.
package enum SettingsPatchRefusal: Error, Equatable {
    // The settings store did not open yet.
    case notOpen
    // The patch has a field that is not a field of the settings, or "version".
    case unknownField(String)
    // The load of settings.json does not keep the value of the field.
    case badValue(Settings.Key)
    // The key edit of the keys field is refused.
    case keys(KeyEditRefusal)
    // The store refused the edit, or the write failed.
    case notSaved(SettingsError)

    package var message: String {
        switch self {
        case .notOpen: "Bifrost can't change the settings yet, because they haven't loaded."
        case .unknownField(let name): "Bifrost has no setting called \"\(name)\"."
        case .badValue(let key): SettingsRefusal.field(key).message
        case .keys(let refusal): refusal.message
        case .notSaved(let error): error.message
        }
    }
}

package struct SettingsPatch: Sendable {
    // The fields with their new values, with no keys field.
    private let fields: [String: JSONValue]
    // The key edit of the keys field, or nil.
    private let keys: KeyEdit?

    // Check the patch against the settings of now.
    package init(_ patch: [String: JSONValue], settings: Settings) throws(SettingsPatchRefusal) {
        let base = Self.fields(of: settings)
        var fields: [String: JSONValue] = [:]
        var keys: KeyEdit?
        for (name, value) in patch.sorted(by: { $0.key < $1.key }) {
            guard let key = Settings.Key(rawValue: name), key != .version else {
                throw .unknownField(name)
            }
            if key == .keys {
                do throws(KeyEditRefusal) {
                    keys = try KeyEdit(patch: value, old: settings.keys)
                } catch {
                    throw .keys(error)
                }
                continue
            }
            guard var object = base else { throw .badValue(key) }
            object[name] = value
            guard let stored = Self.load(object), !stored.defaulted.contains(name) else {
                throw .badValue(key)
            }
            fields[name] = value
        }
        self.fields = fields
        self.keys = keys
    }

    // Apply the patch to the settings, for example the newest settings of an edit. The fields go
    // on top of the fields of the settings, and the load gives the new settings. The settings
    // keep each other field, also a field of a later version. The key edit changes only its
    // slots.
    package func apply(to settings: inout Settings) {
        if !fields.isEmpty, let base = Self.fields(of: settings),
            let stored = Self.load(base.merging(fields) { $1 })
        {
            settings = stored.settings
        }
        if let keys { settings.keys = keys.stored(keeping: settings.keys) }
    }

    // The fields of the settings as settings.json has them, or nil when the encode fails.
    package static func fields(of settings: Settings) -> [String: JSONValue]? {
        guard let data = try? JSONEncoder().encode(settings) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.object
    }

    // The load of the fields with the rules of settings.json, or nil when the decode fails.
    private static func load(_ fields: [String: JSONValue]) -> StoredSettings? {
        guard let data = try? JSONEncoder().encode(JSONValue.object(fields)) else { return nil }
        return try? JSONDecoder().decode(StoredSettings.self, from: data)
    }
}
#endif
