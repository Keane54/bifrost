import Darwin

// Reads the terminal size of a session process, as other clients set it. Bifrost only reads: the
// inspector reads the terminal device of the process, then the size of that device (no ps and no
// stty). It never writes to a TTY.
//
// Each read reads the device again. The device read is a cheap sysctl, and a kept device can
// give a new process with a reused pid the size of the device of the old process.
@MainActor
public struct SessionSizeReader {
    private let inspector: any ProcessInspector

    package init(inspector: any ProcessInspector) {
        self.inspector = inspector
    }

    // The size of the terminal of the process, or nil when the process has no TTY or a read
    // fails.
    package func read(pid: pid_t) async -> TerminalSize? {
        guard let device = await Self.device(inspector, pid) else { return nil }
        return await Self.size(inspector, device)
    }

    // The reads run off the main actor, also with an inspector that does not leave the actor of
    // its caller.
    @concurrent private static func device(_ inspector: any ProcessInspector, _ pid: pid_t) async
        -> String?
    {
        await inspector.terminalDevice(of: pid)
    }

    @concurrent private static func size(_ inspector: any ProcessInspector, _ device: String) async
        -> TerminalSize?
    {
        await inspector.terminalSize(ofDevice: device)
    }
}
