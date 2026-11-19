import BifrostFoundation
import Foundation
import Synchronization

// The file helpers of the store tests. A test makes its folder with TemporaryFolder.

// The file system path of a file URL, with no percent encoding.
package func path(_ url: URL) -> String { url.path(percentEncoded: false) }

// The names of the items in a folder, in sorted order.
package func names(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: path(dir)).sorted()
}

// The JSON value of a saved file.
package func readSaved(_ url: URL) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
}

extension JSONValue {
    // The fields of an object, or nil for another value. A test reads them with #require.
    package var fields: [String: JSONValue]? {
        if case .object(let fields) = self { fields } else { nil }
    }
}

// True when a folder is at the URL.
package func isFolder(_ url: URL) -> Bool {
    var folder: ObjCBool = false
    return FileManager.default.fileExists(atPath: path(url), isDirectory: &folder)
        && folder.boolValue
}

// The steps of a safe write that count the writes that end with the rename. A save can write
// from any thread.
package final class WriteCounter: Sendable {
    private let count = Mutex(0)

    package init() {}

    package var steps: WriteSteps {
        let system = WriteSteps.system
        return WriteSteps(
            sync: system.sync,
            rename: { [self] from, to in
                try system.rename(from, to)
                count.withLock { $0 += 1 }
            })
    }

    package var writes: Int { count.withLock { $0 } }
}
