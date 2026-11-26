import Foundation

// The folders and plain files below some folders of a root, held in memory with their modes, so a
// set-up that many tests share can be made once and written out fresh for each test. A link or
// any other kind of item stops the read, as the image couldn't give it back as it was.
package struct FolderImage: Sendable {
    package struct Failure: Error, CustomStringConvertible {
        package var description: String
    }

    private struct File: Sendable {
        var path: String
        var data: Data
        var mode: Int
    }

    // The folders by path below the root, each one after its parent.
    private var folders: [(path: String, mode: Int)] = []
    private var files: [File] = []

    // An image of the named folders of the root and everything below them.
    package init(of root: String, folders names: [String]) throws {
        for name in names { try add(name, root: root) }
    }

    private mutating func add(_ path: String, root: String) throws {
        let fm = FileManager.default
        let full = root + "/" + path
        let attributes = try fm.attributesOfItem(atPath: full)
        let mode = (attributes[.posixPermissions] as? Int) ?? 0o755
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory?:
            folders.append((path, mode))
            for name in try fm.contentsOfDirectory(atPath: full).sorted() {
                try add(path + "/" + name, root: root)
            }
        case .typeRegular?:
            let data = try Data(contentsOf: URL(filePath: full))
            files.append(File(path: path, data: data, mode: mode))
        default:
            throw Failure(description: "\(full) is neither a folder nor a plain file.")
        }
    }

    // The same image with each plain file that edit changes, for example a config that names
    // the root it came from. edit gets the path below the root and the bytes, and gives nil to
    // keep the bytes as they are.
    package func editing(_ edit: (String, Data) -> Data?) -> FolderImage {
        var copy = self
        for index in copy.files.indices {
            if let data = edit(copy.files[index].path, copy.files[index].data) {
                copy.files[index].data = data
            }
        }
        return copy
    }

    // Write the image below the root.
    package func write(to root: String) throws {
        let fm = FileManager.default
        for folder in folders {
            try fm.createDirectory(
                atPath: root + "/" + folder.path, withIntermediateDirectories: true)
        }
        for file in files {
            let full = root + "/" + file.path
            try file.data.write(to: URL(filePath: full))
            try fm.setAttributes([.posixPermissions: file.mode], ofItemAtPath: full)
        }
        // The modes of the folders go last, so a folder without write permission still gets
        // its files.
        for folder in folders.reversed() {
            try fm.setAttributes(
                [.posixPermissions: folder.mode], ofItemAtPath: root + "/" + folder.path)
        }
    }
}
