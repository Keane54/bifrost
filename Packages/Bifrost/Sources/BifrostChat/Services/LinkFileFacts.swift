import BifrostFoundation
import Foundation
import UniformTypeIdentifiers

extension FileFacts {
    // The facts of the real path of a file for LinkRules.check(_:facts:), from realpath(3),
    // stat(2) and the resource values of the file. nil for a path with a NUL, and when a read
    // fails, for example for a missing file. The reads can wait for a slow volume, so a caller
    // on the main actor calls this off the main actor.
    package init?(atPath path: String) {
        guard let real = RealPath.of(path) else { return nil }
        var info = stat()
        guard stat(real, &info) == 0 else { return nil }
        let isFolder = info.st_mode & S_IFMT == S_IFDIR
        let url = URL(filePath: real, directoryHint: isFolder ? .isDirectory : .notDirectory)
        guard
            let values = try? url.resourceValues(forKeys: [
                .contentTypeKey, .isPackageKey, .isAliasFileKey,
            ]),
            let contentType = values.contentType
        else { return nil }
        self.init(
            realPath: real, contentType: contentType, isFolder: isFolder,
            executable: info.st_mode & 0o111 != 0, isPackage: values.isPackage ?? false,
            isAlias: values.isAliasFile ?? false)
    }
}
