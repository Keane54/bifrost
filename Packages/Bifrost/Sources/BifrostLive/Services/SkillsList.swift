import BifrostFoundation
import Darwin
import Foundation

// The skills of the skills folder of the app, for the Skills section of the settings
// (docs/behaviour/skills.md, The skills list).
// - Each folder in <source>/skills with a SKILL.md is one skill. A link is not a folder, and a
//   SKILL.md that is a link is not read (FolderTree).
// - A SKILL.md that does not parse (SkillCheck) or that has no group is not in the list.
// - The name is the name field, or the name of the folder when the field is missing or empty.
//   The description is the description field, or "" when it is missing.
// - The list is sorted by name. A missing skills folder throws.
package enum SkillsList {
    @concurrent package static func list(_ source: URL) async throws(SyncFailure) -> [SkillInfo] {
        let root = source.appending(path: "skills", directoryHint: .notDirectory)
            .path(percentEncoded: false)
        let skills: [SkillInfo]
        do throws(FileError) {
            guard let folder = try FolderTree.open(root) else {
                throw .system(.read, path: root, code: ENOENT)
            }
            skills = try folder.folders().compactMap { name in
                guard let data = try? folder.read("\(name)/SKILL.md") else { return nil }
                return skill(String(decoding: data, as: UTF8.self), folder: name)
            }
        } catch {
            throw SyncFailure(error)
        }
        return skills.sorted { $0.name < $1.name }
    }

    // The skill of one SKILL.md, or nil when the file does not parse or has no group.
    private static func skill(_ text: String, folder: String) -> SkillInfo? {
        guard case .success(let fields) = SkillCheck.parse(text),
            let group = SkillCheck.group(fields)
        else { return nil }
        let name: String
        if case .text(let value)? = fields["name"], !value.isEmpty {
            name = value
        } else {
            name = folder
        }
        let description: String
        if case .text(let value)? = fields["description"] {
            description = value
        } else {
            description = ""
        }
        return SkillInfo(name: name, description: description, group: group)
    }
}
