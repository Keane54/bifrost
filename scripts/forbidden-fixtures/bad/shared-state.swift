import Foundation

// A file outside the start folder of the services makes the shared paths of a home.
let state = SharedClaudeState(home: URL(fileURLWithPath: "/tmp/x"))
