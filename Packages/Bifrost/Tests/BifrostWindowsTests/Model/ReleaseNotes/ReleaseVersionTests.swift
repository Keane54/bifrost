import Testing

@testable import BifrostWindows

// The version of a release (docs/behaviour/updates.md, "Release notes"): SemVer with an optional
// "v".
@Suite("release version")
struct ReleaseVersionTests {
    @Test func aVersionHasThreeNumbersWithAnOptionalV() {
        #expect(ReleaseVersion("1.2.3")?.description == "1.2.3")
        #expect(ReleaseVersion("v1.2.3")?.description == "1.2.3")
        #expect(ReleaseVersion("0.0.1")?.patch == 1)
        #expect(ReleaseVersion("v1.2.3-beta.2+build.5")?.description == "1.2.3-beta.2")
        #expect(ReleaseVersion("1.2.3-beta.2")?.pre == ["beta", "2"])
    }

    @Test(arguments: [
        "", "v", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "a.b.c", "1.2.x", "1.2.3-", "1.2.3+",
        "1.2.3-be ta", "1.2.3-a..b", " 1.2.3", "1.2.3 ", "V1.2.3", "-1.2.3", "1.2.3-é",
        "99999999999999999999.0.0",
    ])
    func aTextThatIsNotAVersionIsNil(text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func theNumbersAreComparedAsNumbers() {
        #expect(version("1.2.3") < version("1.2.4"))
        #expect(version("1.9.0") < version("1.10.0"))
        #expect(version("2.0.0") > version("1.99.99"))
        #expect(version("1.2.3") == version("v1.2.3+other"))
        #expect(version("0.9.0") <= version("0.9.0"))
    }

    // The rules of SemVer: a pre-release comes before its release, a number part before a text
    // part, and a shorter list of parts before a longer list with the same start.
    @Test func aPreReleaseComesBeforeItsRelease() {
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
            "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        ].map(version)
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            #expect(earlier < later, "\(earlier) < \(later)")
            #expect(!(later < earlier), "\(later) is not < \(earlier)")
        }
        #expect(version("1.0.0-1") < version("1.0.0-alpha"))
    }

    @Test func theBuildPartHasNoEffectOnTheOrder() {
        #expect(!(version("1.0.0+a") < version("1.0.0+b")))
        #expect(!(version("1.0.0+b") < version("1.0.0+a")))
    }
}
