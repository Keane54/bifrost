import Foundation

// The host check app. With --ci it prints the report as one JSON object and exits 1 when any
// check failed, and opened with a double-click it shows the report in an alert instead. In its
// app bundle it finds the host in Contents/Helpers and the test module in Contents/Resources,
// and --host <path> --module <path> point it at a host and a module anywhere else.

// A host that stops reading leaves a broken pipe, which has to come back from write as an error
// rather than as a signal that ends the check app.
signal(SIGPIPE, SIG_IGN)

let usage = "usage: module-host-check [--ci] [--host <path> --module <path>]"

func refuse(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var ci = false
var hostPath: String?
var modulePath: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--ci": ci = true
    case "--host", "--module":
        guard let path = arguments.popFirst() else { refuse(usage) }
        if argument == "--host" { hostPath = path } else { modulePath = path }
    // Finder adds a process serial number on some versions of macOS.
    case let other where other.hasPrefix("-psn_"): continue
    default: refuse(usage)
    }
}

let paths: (host: String, module: String)
switch (hostPath, modulePath) {
case (let host?, let module?):
    paths = (host, module)
case (nil, nil):
    let contents = Bundle.main.bundleURL.appending(path: "Contents")
    paths = (
        contents.appending(path: "Helpers/bifrost-module-host").path(percentEncoded: false),
        contents.appending(path: "Resources/module.js").path(percentEncoded: false)
    )
default:
    refuse(usage)
}
guard FileManager.default.isExecutableFile(atPath: paths.host) else {
    refuse("There's no host to run at \(paths.host)")
}
guard let source = try? String(contentsOfFile: paths.module, encoding: .utf8) else {
    refuse("Can't read the module at \(paths.module)")
}

let report = Report(checks: HostChecks(hostPath: paths.host, source: source).run())
if ci {
    print(report.json)
} else {
    ReportAlert.show(report)
}
exit(report.passed ? 0 : 1)
