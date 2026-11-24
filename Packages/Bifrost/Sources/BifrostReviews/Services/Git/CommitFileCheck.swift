// The checks of the files of a fix commit (docs/behaviour/reviews.md, "What a fix commit can
// hold"): the path rule, the index (a folder, a submodule, or a link that the head holds), the
// file system (a link, a folder above the file that is a link, a file that is not regular, a hard
// link, a file over 1 MiB) and the filter attribute. A file that is not there is a delete: it must
// be an entry of the index, and only the path rule and the index apply to it. A worktree whose
// index or head holds a submodule gets no commit at all (RepoGit.holdsSubmodule).
import BifrostFoundation
import Foundation

package enum CommitFileCheck {
    // The first refusal for the paths of the worktree of the PR, or nil when Bifrost can commit
    // each of them. A failed git or file read refuses (unchecked). No path gives no refusal and
    // runs no git. git runs pinned to the worktree (GitPlace.worktree).
    @concurrent package static func check(_ paths: [String], in pr: PRKey, git: RepoGit) async
        -> CommitFileRefusal?
    {
        await prove(paths, in: pr, git: git).refusal
    }

    // The same check, with the proof of its one submodule check. The proof is nil when the check
    // ran no submodule check, found a submodule, or could not check (the refusal is then set).
    // The caller uses it only with no refusal.
    @concurrent package static func prove(_ paths: [String], in pr: PRKey, git: RepoGit) async
        -> (refusal: CommitFileRefusal?, proof: CommitProof?)
    {
        for path in paths {
            if let refusal = CommitFileRule.pathRefusal(path) { return (refusal, nil) }
        }
        guard !paths.isEmpty else { return (nil, nil) }
        let (holds, proof) = await git.submoduleCheck(pr)
        switch holds {
        case true?: return (.repositoryWithSubmodule, nil)
        case nil: return (.unchecked, nil)
        case false?: break
        }
        return (await files(paths, in: pr, git: git), proof)
    }

    private static func files(_ paths: [String], in pr: PRKey, git: RepoGit) async
        -> CommitFileRefusal?
    {

        let listed = await git.run(.lsFilesStage(paths), in: .worktree(pr))
        guard listed.succeeded, let modes = indexModes(listed.stdout) else { return .unchecked }
        // A path that names a folder lists the entries below it, and git add -A of the folder
        // would add or delete each of them. So each entry must be one of the paths.
        let given = Set(paths)
        if modes.keys.contains(where: { !given.contains($0) }) { return .link }
        for path in paths {
            switch modes[path] {
            case "160000": return .submodule
            case "120000": return .link
            default: break
            }
        }

        let root = GitPlace.worktree(pr, git.layout)
        var present: [String] = []
        for path in paths {
            switch fileState(path, root: root) {
            case .missing:
                // A delete is a delete of one entry of the index.
                if modes[path] == nil { return .unchanged }
            case .plain: present.append(path)
            case .refused(let refusal): return refusal
            }
        }
        guard !present.isEmpty else { return nil }

        let attributes = await git.run(.checkAttrFilter(present), in: .worktree(pr))
        guard attributes.succeeded, let values = filterValues(attributes.stdout),
            values.count == present.count
        else { return .unchecked }
        let unset = values.allSatisfy { $0 == "unspecified" || $0 == "unset" }
        return unset ? nil : .filter
    }

    // MARK: - The index

    // The mode of each path of the output of ls-files --stage -z: "<mode> <object> <stage>\t<path>"
    // for each entry. nil for an output that does not have this form.
    private static func indexModes(_ output: String) -> [String: String]? {
        var modes: [String: String] = [:]
        for entry in output.split(separator: "\0") {
            guard let tab = entry.firstIndex(of: "\t"),
                let mode = entry[..<tab].split(separator: " ").first
            else { return nil }
            modes[String(entry[entry.index(after: tab)...])] = String(mode)
        }
        return modes
    }

    // The values of the output of check-attr -z filter: "<path>\0filter\0<value>\0" for each path.
    private static func filterValues(_ output: String) -> [String]? {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).dropLast()
        guard fields.count % 3 == 0 else { return nil }
        return stride(from: 2, to: fields.count, by: 3).map {
            String(fields[fields.startIndex + $0])
        }
    }

    // MARK: - The file system

    private enum FileState {
        case missing, plain
        case refused(CommitFileRefusal)
    }

    // What is at the path below the root. Each folder above the file must be a real folder, not a
    // link, so the file is inside the worktree. A file that is not there, or a folder above it
    // that is not there or is a file, is a delete.
    private static func fileState(_ path: String, root: String) -> FileState {
        let parts = path.split(separator: "/")
        var current = root
        for (index, part) in parts.enumerated() {
            current += "/" + part
            var info = stat()
            guard lstat(current, &info) == 0 else {
                let code = errno
                return code == ENOENT || code == ENOTDIR ? .missing : .refused(.unchecked)
            }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK { return .refused(.link) }
            if index < parts.count - 1 {
                if kind != S_IFDIR { return .missing }
                continue
            }
            if kind != S_IFREG { return .refused(.link) }
            if info.st_nlink > 1 { return .refused(.hardLink) }
            if info.st_size > Int64(CommitFileRule.maxFileBytes) { return .refused(.tooLarge) }
        }
        return .plain
    }
}
