let same = a != b
let off = !flag
let greeting = "Hello!"
// try! in a comment
// MainActor.assumeIsolated in a comment
let note = "assumeIsolated in a string"
for k in d.keys.sorted() { print(k) }
for (k, v) in d.sorted(by: { $0.key < $1.key }) { print(k, v) }
for (i, x) in a.enumerated() { print(i, x) }
for (x, y) in zip(xs, ys) { print(x, y) }
for (i, k) in d.keys.sorted().enumerated() { print(i, k) }
for v in d.values { total += v }
for (k, v) in d { print(k, v) }
enum JSONValue {}
let nested = "a \(f("q")) b"
let multi = """
    value: \(g("x", count: 2)) done
    """
let units = name.utf16.count
let names = d.keys.sorted()
let total = d.values.reduce(0, +)
let first = d.keys.first
let pairs = d.sorted { $0.key < $1.key }
struct JSONFile {}
struct EventLog {}
for effect in core.takeEffects() { perform(effect) }
let made = performer(value)
import Foundation
// import AppKit and NSClassFromString in a comment
let text = "NSClassFromString(\"CAFilter\") and import AppKit"
// SharedClaudeState(home: x) in a comment
let shared: SharedClaudeState = services.sharedState
let named = "SharedClaudeState(home: x)"
// import Darwin and FileManager in a comment
buffer.append(contentsOf: bytes)
let table = ProcessTable()
let raw = #"try! and value! and "quoted" text"#
let rawEscape = #"a \"# + "b"
let rawBlock = ##"""
    try! and value! and """# inside
    """##
let rawInterpolation = #"count: \#(items.count) and \(not code!)"#
let pattern = /value!/
let bang = #/a!b/#
let matched = text.contains(/try!/)
let ratio = total / count / 2
// spawner.spawn(program: path) in a comment
let spawnText = "spawner.spawn(program: path)"
func spawn(program: String, arguments: [String]) {}
log.events.append(.spawn(size))
package func spawn(
    program: String, arguments: [String]
) throws -> Int { 0 }
// PTYProcess(program: path) and PTYProcess.init in a comment
let processText = "PTYProcess(program: path)"
let send = PTYProcess.defaultSend
let process: PTYProcess? = nil
let fake = FakePTYProcess(pid: 1)
// import Security and SecItemCopyMatching in a comment
let tool = "/usr/bin/security find-generic-password and SecItemAdd in a string"
let securityPath = AccessToken.securityPath
