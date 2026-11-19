import BifrostFoundation
import Foundation

// Writes the skill export (SkillExport) to settings.json in the Daily update folder. The folder
// gets mode 0700, also a folder from before, and the file mode 0600 through the safe write of the
// stores (JSONFile.write). The write waits for a full sync, so it runs on the blocking executor.
// The caller runs one write at a time, so an older export never writes over a newer one.
package struct SkillExportWriter: Sendable {
    package let layout: DailyLayout

    package init(layout: DailyLayout) {
        self.layout = layout
    }

    @concurrent package func write(_ settings: DailySettings) async throws(FileError) {
        let export = SkillExport(settings)
        let folder = layout.folder
        let file = layout.exportFile
        try await BlockingExecutor.run { () throws(FileError) in
            try PrivateFolder.make(folder)
            do {
                try JSONFile.write(JSONFile.encode(export), to: file)
            } catch {
                throw FileError(error, call: .save, path: file.path(percentEncoded: false))
            }
        }
    }
}
