import BifrostFoundation
import Foundation

// The reads of the section "Limits and disk" of the panel (docs/behaviour/health.md,
// "Performance"): the free space of the volume of the home, and the size of the Reviews clones.
package struct DiskState: Sendable {
    // The home folder of the app. A test home gives the volume of the test home.
    package let home: URL
    // The repos root of Reviews, or nil when the app has no clones folder.
    package let clones: URL?

    package init(home: URL, clones: URL?) {
        self.home = home
        self.clones = clones
    }

    // The free space for important data on the volume of the home, as Finder shows it. nil when
    // the read fails.
    @concurrent package func freeSpace() async -> UInt64? {
        let home = home
        return await BlockingExecutor.run {
            let values = try? home.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ])
            return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
        }
    }

    // The size of all files below the clones folder: the space on the disk, as du gives it. The
    // walk does not follow a link. nil when the folder is not there. A walk of many files takes
    // time, so it runs on the blocking executor.
    @concurrent package func clonesSize() async -> UInt64? {
        guard let clones else { return nil }
        return await BlockingExecutor.run { Self.size(of: clones) }
    }

    private static func size(of folder: URL) -> UInt64? {
        var isFolder: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: folder.path(percentEncoded: false), isDirectory: &isFolder),
            isFolder.boolValue
        else { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard
            let walk = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: Array(keys), options: [],
                errorHandler: { _, _ in true })
        else { return nil }
        var total: UInt64 = 0
        for case let file as URL in walk {
            guard let values = try? file.resourceValues(forKeys: keys),
                values.isRegularFile == true, let size = values.totalFileAllocatedSize
            else { continue }
            total += UInt64(max(size, 0))
        }
        return total
    }
}
