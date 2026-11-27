import AppKit

// The report for someone who opened the app with a double-click: one alert with a line for each
// check, and a button that copies the report as JSON so it can be sent on exactly as it is.
@MainActor
enum ReportAlert {
    static func show(_ report: Report) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate()
        let failed = report.checks.count { !$0.passed }
        let alert = NSAlert()
        alert.alertStyle = failed == 0 ? .informational : .warning
        alert.messageText =
            failed == 0
            ? "Every check passed" : "\(failed) of \(report.checks.count) checks failed"
        alert.informativeText = report.lines.joined(separator: "\n")
        alert.addButton(withTitle: "Copy report")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report.json, forType: .string)
        }
    }
}
