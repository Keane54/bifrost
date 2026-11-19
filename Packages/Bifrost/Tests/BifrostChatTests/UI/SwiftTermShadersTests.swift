import BifrostTestSupport
import Foundation
import Testing

// The app compiles a copy of the shaders of SwiftTerm (App/Bifrost/SwiftTermShaders.metal), so
// the Metal renderer of a chat loads them and does not compile them at run time. The copy must
// be the file of the SwiftTerm version that the package and the app resolve, and it must have
// each function that the renderer needs.
@Suite("SwiftTerm shaders", .tags(.window))
struct SwiftTermShadersTests {
    private struct Resolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { var version: String? }
            var identity: String
            var state: State
        }
        var pins: [Pin]
    }

    // A class of the test bundle, to find the bundle.
    private final class BundleMark {}

    // The functions that the Metal renderer of SwiftTerm 1.99.3 needs in a library.
    private static let functions = [
        "terminal_text_vertex", "terminal_cell_text_vertex", "terminal_text_fragment",
        "terminal_text_fragment_gray", "terminal_color_vertex", "terminal_cell_color_vertex",
        "terminal_color_fragment",
    ]

    // The copy, split into its header (the first comment lines) and the text below the blank
    // line after the header.
    private static func copy() throws -> (header: String, body: String) {
        let text = try String(
            contentsOf: try Repo.root().appending(path: "App/Bifrost/SwiftTermShaders.metal"),
            encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let header = lines.prefix { $0.hasPrefix("//") }
        let rest = lines.dropFirst(header.count)
        try #require(rest.first == "", "a blank line follows the header")
        return (header.joined(separator: "\n"), rest.dropFirst().joined(separator: "\n"))
    }

    // The SwiftTerm version of a Package.resolved file of the repo.
    private static func version(in path: String) throws -> String {
        let data = try Data(contentsOf: try Repo.root().appending(path: path))
        let resolved = try JSONDecoder().decode(Resolved.self, from: data)
        let pin = try #require(resolved.pins.first { $0.identity == "swiftterm" })
        return try #require(pin.state.version)
    }

    @Test func theCopyIsOfTheVersionThatThePackageAndTheAppResolve() throws {
        let package = try Self.version(in: "Packages/Bifrost/Package.resolved")
        let app = try Self.version(
            in: "Bifrost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        #expect(package == app)
        let header = try Self.copy().header
        let source = "Sources/SwiftTerm/Apple/Metal/Shaders.metal"
        #expect(header.hasPrefix("// A copy of \(source) of SwiftTerm \(package) "))
    }

    // The checkout of SwiftTerm is in the scratch folder of the build (.build or .build/pkg),
    // three folders above the test bundle.
    @Test func theCopyIsTheFileOfTheCheckout() throws {
        let scratch = (0..<3).reduce(Bundle(for: BundleMark.self).bundleURL) { url, _ in
            url.deletingLastPathComponent()
        }
        let shaders = scratch.appending(
            path: "checkouts/SwiftTerm/Sources/SwiftTerm/Apple/Metal/Shaders.metal")
        guard let checkout = FileManager.default.contents(atPath: shaders.path) else {
            Issue.record("no SwiftTerm checkout at \(shaders.path)")
            return
        }
        #expect(Data(try Self.copy().body.utf8) == checkout)
    }

    @Test func theCopyHasEachFunctionThatTheRendererNeeds() throws {
        let body = try Self.copy().body
        for name in Self.functions {
            #expect(body.contains(" \(name)("), "\(name)")
        }
    }
}
