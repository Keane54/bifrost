import BifrostApp
import BifrostFoundation
import Testing

private let development = AppIdentity(bundleID: "com.example.app.native-dev")
private let release = AppIdentity(bundleID: "com.example.app")

@Test func noIdentityStopsTheStart() {
    #expect(StartRule.problem(identity: nil, isDebugBuild: true) == .missingIdentity)
    #expect(StartRule.problem(identity: nil, isDebugBuild: false) == .missingIdentity)
}

@Test func aDebugBuildWithTheReleaseIdentityStopsTheStart() throws {
    let identity = try #require(release)
    #expect(StartRule.problem(identity: identity, isDebugBuild: true)
        == .releaseIdentityInDebugBuild)
}

@Test func aDebugBuildWithTheDevelopmentIdentityStarts() throws {
    let identity = try #require(development)
    #expect(StartRule.problem(identity: identity, isDebugBuild: true) == nil)
}

@Test func aReleaseBuildStartsWithEitherIdentity() throws {
    let releaseIdentity = try #require(release)
    let developmentIdentity = try #require(development)
    #expect(StartRule.problem(identity: releaseIdentity, isDebugBuild: false) == nil)
    #expect(StartRule.problem(identity: developmentIdentity, isDebugBuild: false) == nil)
}
