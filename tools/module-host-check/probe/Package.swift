// swift-tools-version: 6.2
import PackageDescription

// The host check app, which stands in for Heimdall: it starts the real module host the way
// Heimdall will and checks what comes back. It's its own package so the Bifrost package never
// links AppKit near the host, and scripts/module-host-check/build.sh puts it in an app bundle
// with the host and the test module. It takes the same upcoming features as Packages/Bifrost.
let package = Package(
    name: "module-host-check",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "module-host-check",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("ExistentialAny"),
            ])
    ],
    swiftLanguageModes: [.v6]
)
