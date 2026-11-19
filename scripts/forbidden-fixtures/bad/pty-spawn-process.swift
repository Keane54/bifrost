// A file that is not the system spawner makes a PTYProcess: a call, a call of the init over two
// lines, and a reference to the init.
let child = try PTYProcess(program: path, arguments: [], environment: env, directory: "/",
    size: size)
let other = try PTYProcess.init(
    program: path, arguments: [], environment: env, directory: "/", size: size)
let make = PTYProcess
    .init
