import Testing
import Foundation

// The sample answers of GitHub in Fixtures/. Each helper reads from the test bundle: no network.
enum FixtureFiles {
    static func data(_ name: String) throws -> Data {
        let folder = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: folder.appending(path: "\(name).json"))
    }

    // The fixture after a change of its JSON, for a case that a file does not hold.
    static func edited(_ name: String, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var root = try #require(
            JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
        change(&root)
        return try JSONSerialization.data(withJSONObject: root)
    }
}

// The path of the list of PRs in a poll answer: data.<list>.nodes.
func edit(
    _ root: inout [String: Any], list: String, _ change: (inout [String: Any]) -> Void
) {
    var data = root["data"] as? [String: Any] ?? [:]
    var search = data[list] as? [String: Any] ?? [:]
    change(&search)
    data[list] = search
    root["data"] = data
}

// A change of the PR with this number in a list of a poll answer.
func editPR(
    _ root: inout [String: Any], list: String, number: Int,
    _ change: (inout [String: Any]) -> Void
) {
    edit(&root, list: list) { search in
        var nodes = search["nodes"] as? [[String: Any]] ?? []
        let found = nodes.firstIndex { $0["number"] as? Int == number }
        guard let index = found else { return }
        change(&nodes[index])
        search["nodes"] = nodes
    }
}
