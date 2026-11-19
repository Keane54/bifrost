import BifrostApp
import BifrostFoundation
import Testing

// The development app can start with or without the cutover condition.
@Test func developmentMayStart() {
    #expect(StartGuard.mayStart(variant: .development, cutover: false))
    #expect(StartGuard.mayStart(variant: .development, cutover: true))
}

// Before cutover, the release app has the bundle ID of the Electron app. It must not start.
@Test func aReleaseBeforeCutoverMayNotStart() {
    #expect(!StartGuard.mayStart(variant: .release, cutover: false))
}

@Test func aReleaseAtCutoverMayStart() {
    #expect(StartGuard.mayStart(variant: .release, cutover: true))
}
