import Foundation

// A reference to the init, with no call here, makes the shared paths later.
let make = SharedClaudeState.init
let state = make(URL(fileURLWithPath: "/tmp/x"))
