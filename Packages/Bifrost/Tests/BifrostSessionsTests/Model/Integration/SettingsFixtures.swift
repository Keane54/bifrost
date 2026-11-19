import Foundation

@testable import BifrostSessions

// The settings of a JSON text.
func settings(_ text: String) throws -> ClaudeSettingsDocument {
    try ClaudeSettingsDocument.parse(Data(text.utf8))
}

// One JSON value of a JSON text.
func jsonValue(_ text: String) throws -> ClaudeSettingsDocument.Value {
    try ClaudeSettingsDocument.parseValue(Data(text.utf8))
}

// A Bifrost hook, as the old hook install wrote it.
let bifrostHookJSON = #"{"command":"~/.bifrost/bin/bifrost-hook","type":"command"}"#

// The wrapper, as the old hook install wrote it.
let wrapperJSON = #"{"command":"~/.bifrost/bin/bifrost-statusline","type":"command"}"#

// The settings of an old hook install: the keys of base, then for each row a hook entry after the
// entries of the user under its event, and the wrapper. The wrapper keeps the refreshInterval and
// the padding of the statusLine of the user. A key of base keeps its place.
func oldInstalled(_ base: ClaudeSettingsDocument = ClaudeSettingsDocument()) throws
    -> ClaudeSettingsDocument
{
    var next = base
    var hooks = base["hooks"]?.object ?? ClaudeSettingsDocument()
    for row in SettingsPlan.hookRows {
        var entry = ClaudeSettingsDocument()
        if let matcher = row.matcher { entry.setValue(.string(.init(matcher)), forKey: "matcher") }
        entry.setValue(try jsonValue("[\(bifrostHookJSON)]"), forKey: "hooks")
        let old = hooks[row.event]?.array ?? []
        hooks.setValue(.array(old + [.object(entry)]), forKey: row.event)
    }
    next.setValue(.object(hooks), forKey: "hooks")
    var wrapper = try settings(wrapperJSON)
    for key in ["refreshInterval", "padding"] {
        if let value = base["statusLine"]?.object?[key] { wrapper.setValue(value, forKey: key) }
    }
    next.setValue(.object(wrapper), forKey: "statusLine")
    return next
}
