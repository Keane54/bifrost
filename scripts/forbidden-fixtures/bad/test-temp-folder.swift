let folder = FileManager.default.temporaryDirectory.appendingPathComponent("x")
let old = NSTemporaryDirectory()
let made = mkdtemp(&template)
