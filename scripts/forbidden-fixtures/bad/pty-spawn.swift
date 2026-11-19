// A file that is not the PTY manager spawns a PTY child, on one line, over two lines and with
// no receiver in a type that conforms to the spawner.
let child = try spawner.spawn(program: path, arguments: ["attach", id], environment: env,
    directory: "/", size: size)
let other = try spawner.spawn(
    program: path, arguments: ["attach", "--", id], environment: env, directory: "/", size: size)
extension LoggingSpawner {
    func attach(_ id: String) throws -> any PTYChild {
        try spawn(program: path, arguments: ["attach", id], environment: env, directory: "/",
            size: size)
    }
}
