import Testing

@testable import BifrostFoundation

@Test func developmentIdentityFromTheSuffixedID() throws {
    let id = try #require(AppIdentity(bundleID: "com.example.app.native-dev"))
    #expect(id.variant == .development)
    #expect(id.releaseBundleID == "com.example.app")
    #expect(id.supportFolderName == "Bifrost Native Dev")
    #expect(id.dotFolderName == ".bifrost-native-dev")
}

@Test func releaseIdentity() throws {
    let id = try #require(AppIdentity(bundleID: "com.example.app"))
    #expect(id.variant == .release)
    #expect(id.releaseBundleID == "com.example.app")
    #expect(id.supportFolderName == "Bifrost")
    #expect(id.dotFolderName == ".bifrost")
}

@Test func noIdentityWithoutABundleID() {
    #expect(AppIdentity(bundleID: nil) == nil)
    #expect(AppIdentity(bundleID: "") == nil)
}

@Test func noIdentityWhenTheReleasePartIsEmpty() {
    #expect(AppIdentity(bundleID: ".native-dev") == nil)
}

@Test func theSuffixCountsOnlyAtTheEnd() throws {
    let id = try #require(AppIdentity(bundleID: "com.example.native-dev.app"))
    #expect(id.variant == .release)
}
