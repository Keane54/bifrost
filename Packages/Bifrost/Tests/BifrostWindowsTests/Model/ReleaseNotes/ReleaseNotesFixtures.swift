import Foundation

@testable import BifrostWindows

// The Releases page of the tests and the page of one release below it.
let releasesPage = URL(string: "https://github.com/example/bifrost/releases") ?? URL(filePath: "/")

func releasePage(_ tag: String) -> String { "\(releasesPage.absoluteString)/tag/\(tag)" }

// A body as the release workflow writes it.
let fullBody = """
    Release of the new window.

    ## 1.2.0 (2026-11-10)

    ### ⚠ BREAKING CHANGES

    * **settings:** the key file moved ([abc1234](https://example.invalid/c/abc1234))

    ### Features

    * **chat:** a **bold** and `code` item ([def5678](https://example.invalid/c/def5678))
    * an item with no scope

    ### Bug Fixes

    * **keys:** fix one ([0123abc](https://x.invalid/0123abc)), closes [#12](https://x.invalid)

    ### Documentation

    * **docs:** a hidden item ([1111111](https://example.invalid/c/1111111))

    ### Performance Improvements

    * **ui:** faster ([2222222](https://example.invalid/c/2222222))
    """

// One entry of the GitHub answer, as JSON text.
func releaseJSON(
    tag: String, date: String = "2026-11-10T09:00:00Z", body: String? = "", draft: Bool = false,
    prerelease: Bool = false, page: String? = nil
) -> String {
    var fields = [
        "\"tag_name\": \"\(tag)\"", "\"published_at\": \"\(date)\"",
        "\"html_url\": \"\(page ?? releasePage(tag))\"", "\"draft\": \(draft)",
        "\"prerelease\": \(prerelease)",
    ]
    if let body {
        let escaped = body.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        fields.append("\"body\": \"\(escaped)\"")
    } else {
        fields.append("\"body\": null")
    }
    return "{" + fields.joined(separator: ", ") + "}"
}

func releasesAnswer(_ entries: String...) -> Data {
    Data(("[" + entries.joined(separator: ",") + "]").utf8)
}

func version(_ text: String) -> ReleaseVersion {
    guard let version = ReleaseVersion(text) else { preconditionFailure("not a version: \(text)") }
    return version
}

func release(_ text: String, summary: String = "") -> Release {
    Release(
        version: version(text), date: Date(timeIntervalSince1970: 0),
        page: URL(string: releasePage("v\(text)")) ?? releasesPage, summary: summary)
}
