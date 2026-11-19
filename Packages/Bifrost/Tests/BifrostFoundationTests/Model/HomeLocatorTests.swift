import Foundation
import Testing

@testable import BifrostFoundation

// The test home: its config, the homes that the app refuses and the error texts. The app finds
// its folders with DataFolders. The tests of the links run with the real file system in
// BifrostAppTests/Services/TestHomeTests.swift.

private let realHome = "/Users/o"
private let key = HomeLocator.testHomeKey

private func env(_ value: String?) -> [String: String] {
    guard let value else { return [:] }
    return [key: value]
}

// A check with no links: each path is its own real path.
private func noLinks(ignoresCase: Bool) -> PathCheck {
    PathCheck(ignoresCase: ignoresCase) { _ in nil }
}

private let macOS = noLinks(ignoresCase: true)

private func config(_ value: String?, check: PathCheck = macOS) -> String? {
    HomeLocator.testHome(environment: env(value), realHome: realHome, check: check)
}

private func refused(_ value: String?, check: PathCheck = macOS) -> String? {
    HomeLocator.refusedTestHome(environment: env(value), realHome: realHome, check: check)
}

@Suite("test home")
struct TestHomeTests {
    @Test("the test home variable sets the home")
    func variable() {
        #expect(HomeLocator.testHomeKey == "BIFROST_TEST_HOME")
    }

    @Test
    func givesTheHome() {
        #expect(config("/tmp/bh") == "/tmp/bh")
        // The value is normalised.
        #expect(config("/tmp//bh/x/../") == "/tmp/bh")
    }

    @Test("no value gives no test home")
    func noValue() {
        #expect(HomeLocator.testHome(environment: [:], realHome: realHome, check: macOS) == nil)
        #expect(config(nil) == nil)
        #expect(config("") == nil)
    }

    @Test
    func refusesBadValues() {
        for bad in ["x", "tmp/bh", "./bh", "/", "//", "/Users/o", "/Users/o/", "/Users"] {
            #expect(config(bad) == nil, "\(bad)")
        }
        // A path that only looks like the real home after normalisation is refused too.
        #expect(config("/Users/o/tmp/..") == nil)
        // A folder that starts with the same letters is not a parent.
        #expect(config("/Users/ol") == "/Users/ol")
        #expect(config("/Users/o/tmp/t") == "/Users/o/tmp/t")
    }

    // The app writes its shared state in the test home, so a test home in a folder of the
    // shared state of the real home is refused, also with another case.
    @Test
    func refusesAFolderOfTheSharedState() {
        for bad in [
            "/Users/o/.claude", "/Users/o/.claude/t", "/Users/o/.claude.json",
            "/Users/o/.bifrost/x", "/Users/o/.bifrost-native-dev",
            "/Users/o/Library/Application Support/Bifrost/t",
            "/Users/o/Library/Application Support/Bifrost Native Dev",
            "/USERS/O/.CLAUDE/t",
        ] {
            #expect(config(bad) == nil, "\(bad)")
            #expect(refused(bad) == bad, "\(bad)")
        }
        // A folder that only starts with the same letters is not a shared folder.
        for good in [
            "/Users/o/.claude-test", "/Users/o/.bifrostx", "/Users/o/Library/Application Support",
            "/Users/o/Library/Application Support/Bifrost Other",
        ] {
            #expect(config(good) == good, "\(good)")
        }
        // Another file system compares the case.
        #expect(
            config("/Users/o/.CLAUDE/t", check: noLinks(ignoresCase: false))
                == "/Users/o/.CLAUDE/t")
    }

    @Test("a refused value stops the start")
    func refusedValues() {
        for bad in ["x", "/", "/Users/o", "/Users"] {
            #expect(refused(bad) == bad, "\(bad)")
        }
        #expect(refused("/tmp/bh") == nil)
        #expect(
            HomeLocator.refusedTestHome(environment: [:], realHome: realHome, check: macOS) == nil)
        #expect(refused(nil) == nil)
    }

    // A variable that is set but empty must not use the real home by mistake.
    @Test("an empty value is refused")
    func emptyValue() {
        #expect(refused("") == "")
        #expect(
            HomeLocator.refusalText("")
                == "Bifrost can't use the test home (empty). Use an absolute folder that isn't /, "
                + "your home folder, a parent of it, or a data folder of Claude Code or Bifrost.")
        #expect(
            HomeLocator.refusalText("/Users")
                == "Bifrost can't use the test home /Users. Use an absolute folder that isn't /, "
                + "your home folder, a parent of it, or a data folder of Claude Code or Bifrost.")
    }

    // The check ignores the case on macOS (the value ignoresCase).
    @Test("paths compare without case on macOS")
    func ignoresCase() {
        for bad in ["/USERS/O", "/users/O/", "/USERS"] {
            #expect(config(bad) == nil, "\(bad)")
            #expect(refused(bad) == bad, "\(bad)")
        }
        // Another file system compares the case.
        #expect(config("/USERS/O", check: noLinks(ignoresCase: false)) == "/USERS/O")
        // A child folder of the real home in another case is still accepted.
        #expect(config("/USERS/O/tmp/t") == "/USERS/O/tmp/t")
    }

    // The launch code gives the real home, so the check never reads HOME.
    @Test
    func testHomeIsHome() {
        let testDir = "/tmp/bifrost-th-home"
        let environment = [key: testDir, "HOME": testDir]
        #expect(
            HomeLocator.testHome(environment: environment, realHome: realHome, check: macOS)
                == testDir)
        #expect(
            HomeLocator.refusedTestHome(environment: environment, realHome: realHome, check: macOS)
                == nil)
    }

    @Test
    func realHomeWithOtherHome() {
        for bad in [realHome, "/Users"] {
            let environment = [key: bad, "HOME": "/tmp/bifrost-th-home"]
            #expect(
                HomeLocator.testHome(environment: environment, realHome: realHome, check: macOS)
                    == nil, "\(bad)")
            #expect(
                HomeLocator.refusedTestHome(
                    environment: environment, realHome: realHome, check: macOS) == bad, "\(bad)")
        }
    }
}

// The choice of the launch code: the release app always uses the real home, and the
// development app uses a good test home or does not start.
@Suite("the home of the app")
struct HomeChoiceTests {
    private let real = URL(fileURLWithPath: "/Users/o", isDirectory: true)

    private func choose(_ variant: AppVariant, _ environment: [String: String]) -> HomeChoice {
        HomeLocator.choose(variant: variant, environment: environment, realHome: real, check: macOS)
    }

    @Test func releaseIgnoresTheTestHome() {
        for value in ["/tmp/h", "", "x", "/"] {
            #expect(choose(.release, [key: value]) == .home(real, isTest: false), "\(value)")
        }
        #expect(choose(.release, [:]) == .home(real, isTest: false))
    }

    @Test func developmentUsesAGoodTestHome() {
        let home = URL(fileURLWithPath: "/tmp/h", isDirectory: true)
        #expect(choose(.development, [key: "/tmp/h/"]) == .home(home, isTest: true))
    }

    @Test func developmentWithoutATestHomeUsesTheRealHome() {
        #expect(choose(.development, [:]) == .home(real, isTest: false))
    }

    // A refused value never falls back to the real home.
    @Test func developmentRefusesABadTestHome() {
        for value in ["", "tmp/h", "/", "/Users/o", "/Users", "/USERS/O"] {
            #expect(choose(.development, [key: value]) == .refused(value), "\(value)")
        }
    }
}
