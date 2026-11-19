let gh = Command("gh", ["api"])
let git = Command.init("git", ["status"])
let other: Command = .init("git")
