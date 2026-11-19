import Darwin

// The real path of a path (realpath(3)): absolute, with each link resolved and with no "." and
// no "..". The app checks paths, finds the folder of a branch and opens links with it.
package enum RealPath {
    // nil when no file is at the path, for an empty path, and for a path with a NUL character:
    // the C string of the call ends at the NUL, so the call would read another path.
    package static func of(_ path: String) -> String? {
        guard !path.isEmpty, !path.contains("\0"), let resolved = realpath(path, nil) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
