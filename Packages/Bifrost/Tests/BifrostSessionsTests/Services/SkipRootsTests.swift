// The skip roots (docs/behaviour/actions.md, "The process probe"): a path at or below a review
// folder, by its normal form or by its real path.
import Testing

@testable import BifrostSessions

// The real paths of a test: a path that the map does not have does not exist.
private func realPaths(_ map: [String: String]) -> (String) async -> String? {
    { map[$0] }
}

@Suite("the skip roots")
struct SkipRootsTests {
    @Test(
        "a path at or below a root counts in its normal form",
        arguments: [
            (["/r/reviews/"], "/r/reviews"), (["/r/reviews/"], "/r/reviews/pr"),
            (["/r/reviews"], "/r/reviews/"), (["/r/reviews"], "/r//reviews//pr"),
            (["/r/reviews"], "/r/./reviews/pr"), (["/r/reviews"], "/r/reviews/pr/.."),
            (["/r/./reviews/"], "/r/reviews/pr"), (["/x", "/r/reviews"], "/r/reviews/a b"),
            (["/r/reviews"], "//r/reviews/pr"),
        ])
    func below(roots: [String], path: String) async {
        #expect(await SkipRoots(roots).contains(path, realPath: realPaths([:])))
    }

    @Test(
        "a path beside or above a root does not count",
        arguments: [
            (["/r/reviews"], "/r/reviews/.."), (["/r/reviews"], "/r/reviews/../x"),
            (["/r/reviews"], "/r/reviews-old"), (["/r/reviews"], "/r"),
            (["/r/reviews/"], "/r/review"), ([], "/r/reviews"),
        ])
    func notBelow(roots: [String], path: String) async {
        #expect(!(await SkipRoots(roots).contains(path, realPath: realPaths([:]))))
    }

    // A link outside a root can point into it, and a root can be a link.
    @Test func theRealPathsCountToo() async {
        let roots = SkipRoots(["/r/reviews"])
        let linkIn = realPaths(["/link": "/r/reviews/pr", "/r/reviews": "/r/reviews"])
        #expect(await roots.contains("/link", realPath: linkIn))
        let linkRoot = SkipRoots(["/rlink"])
        let paths = realPaths(["/rlink": "/r/reviews", "/r/reviews/pr": "/r/reviews/pr"])
        #expect(await linkRoot.contains("/r/reviews/pr", realPath: paths))
        #expect(!(await linkRoot.contains("/r/other", realPath: paths)))
    }
}
