// swift-tools-version: 6.2
import PackageDescription

// The settings of each target of the package, in each build (swift build, swift test and the
// Debug and Release builds of the app):
// - the concurrency features SE-0461 and SE-0470. Config/Base.xcconfig turns on the same features
//   for the app target. The modules have no default isolation: each type of the UI folders states
//   @MainActor, so one module can hold pure rules, services and views;
// - SE-0444: a file can use a member of a module only when the file imports that module;
// - SE-0335: each existential type has "any".
// The list has no .treatAllWarnings(as: .error). Xcode builds the targets of this package with
// -suppress-warnings, and swiftc refuses that flag together with -warnings-as-errors. Thus
// scripts/check.sh gives -warnings-as-errors to its SwiftPM builds (the tests and a release
// build).
let features: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
]

// One module for each domain of the app (docs/specs/2026-11-14-native-architecture-design.md).
// Each module has the folders Model (pure types and rules: no I/O, no AppKit, no SwiftUI),
// Services (state, processes, files and sockets: no AppKit, no SwiftUI) and UI (AppKit and
// SwiftUI), as it needs them. A module uses only the modules before it in the list of targets.
func module(_ name: String, _ dependencies: [Target.Dependency] = []) -> Target {
    .target(name: name, dependencies: dependencies, swiftSettings: features)
}

// The tests of a module. The test support module has the shared fakes and helpers.
// The data files of a test target are its resources: a test reads them through Bundle.module.
func tests(_ name: String, _ dependencies: [Target.Dependency], resources: [Resource] = [])
    -> Target
{
    .testTarget(
        name: name + "Tests", dependencies: [.target(name: name), "BifrostTestSupport"]
            + dependencies, resources: resources, swiftSettings: features)
}

let package = Package(
    name: "Bifrost",
    platforms: [.macOS(.v26)],
    // The modules that the app target of Bifrost.xcodeproj imports.
    products: [
        "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostKeyboard", "BifrostSessions",
        "BifrostSettings", "BifrostDictation", "BifrostChat", "BifrostWindows", "BifrostApp",
    ].map { .library(name: $0, targets: [$0]) },
    dependencies: [
        // The terminal of the chat windows: an exact version. The chat terminal uses it, and the
        // key scenarios of the tests type into a real terminal view.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3")
    ],
    targets: [
        module("BifrostFoundation"),
        module("BifrostLayout", ["BifrostFoundation"]),
        .target(
            name: "BifrostLook",
            dependencies: ["BifrostFoundation", "BifrostLayout"],
            // The app build compiles the shader of the background into the default library of
            // the bundle. A command-line build copies the source.
            resources: [
                .copy("Resources/Fonts"), .copy("Resources/Icons"), .process("UI/Background.metal"),
            ],
            swiftSettings: features
        ),
        module("BifrostKeyboard", ["BifrostFoundation", "BifrostLayout"]),
        // The panels of the session features (the Event log) use the panel IDs and the look.
        module("BifrostSessions", ["BifrostFoundation", "BifrostLayout", "BifrostLook"]),
        module("BifrostLive", ["BifrostFoundation", "BifrostSessions"]),
        // The rules and the services of Reviews. Its panels live in BifrostWindows.
        module(
            "BifrostReviews",
            ["BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostSessions"]),
        // The rules and the state of the Daily update. Its panel and services come in later tasks.
        module("BifrostDailyUpdate", ["BifrostFoundation", "BifrostSessions"]),
        // The rules, the services and the panels of Service status and Performance. Performance
        // reads the GitHub points through the gh command of BifrostFoundation (GHCommand).
        module(
            "BifrostHealth",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostSessions",
            ]),
        // The Settings panel opens and closes in the layout. Settings > Live details and
        // Settings > Skills use the controls of BifrostLive.
        module(
            "BifrostSettings",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostKeyboard",
                "BifrostSessions", "BifrostLive", "BifrostReviews", "BifrostDailyUpdate",
            ]),
        module("BifrostDictation", ["BifrostFoundation", "BifrostLook", "BifrostKeyboard"]),
        module(
            "BifrostChat",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostKeyboard",
                "BifrostSessions", "BifrostSettings", "BifrostDictation",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]),
        module(
            "BifrostWindows",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostKeyboard",
                "BifrostSessions", "BifrostReviews", "BifrostSettings", "BifrostDictation",
                "BifrostChat", "BifrostDailyUpdate",
            ]),
        // The app module joins the features: the services of the app, the shell of the window,
        // the start and the debug test port and bench.
        module(
            "BifrostApp",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostKeyboard",
                "BifrostSessions", "BifrostLive", "BifrostReviews", "BifrostSettings",
                "BifrostDictation", "BifrostChat", "BifrostWindows", "BifrostHealth",
                "BifrostDailyUpdate", .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]),
        // The shared fakes and helpers of the tests. The app never links it.
        module(
            "BifrostTestSupport",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostKeyboard", "BifrostSessions",
                "BifrostReviews", "BifrostDictation", "BifrostChat", "BifrostWindows",
                "BifrostHealth", "BifrostDailyUpdate",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]),
        // The tests of a module test that module. A test can also use another module when it joins
        // two modules (for example the dictation of a chat in a real canvas of BifrostWindows).
        tests("BifrostFoundation", []),
        tests("BifrostLayout", ["BifrostFoundation"]),
        tests("BifrostLook", ["BifrostLayout"]),
        tests("BifrostKeyboard", ["BifrostFoundation"]),
        // The real sample of the output of claude agents --json, and a registry file.
        tests(
            "BifrostSessions", ["BifrostFoundation", "BifrostLayout", "BifrostLook"],
            resources: [.copy("Services/Fixtures")]),
        tests("BifrostLive", ["BifrostFoundation", "BifrostSessions"]),
        // The sample answers of GitHub for the tests of Reviews.
        tests(
            "BifrostReviews", ["BifrostFoundation", "BifrostLayout", "BifrostSessions"],
            resources: [.copy("Fixtures")]),
        // The sample answers of the status pages for the tests of Service status.
        tests(
            "BifrostHealth",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostSessions",
            ],
            resources: [.copy("Fixtures")]),
        // The settings and the state files of the Daily update, as the Electron app wrote them.
        tests(
            "BifrostDailyUpdate", ["BifrostFoundation", "BifrostSessions"],
            resources: [.copy("Fixtures")]),
        // The Keys tests check the menu that a new menu key gives, and the Live details tests
        // check the dot of the side bar (BifrostWindows).
        tests(
            "BifrostSettings",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostKeyboard",
                "BifrostSessions", "BifrostLive", "BifrostReviews", "BifrostWindows",
                "BifrostDailyUpdate",
            ]),
        tests(
            "BifrostDictation",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostKeyboard",
                "BifrostSessions",
            ]),
        tests(
            "BifrostChat",
            [
                "BifrostLayout", "BifrostLook", "BifrostKeyboard", "BifrostSessions",
                "BifrostSettings", "BifrostDictation", "BifrostWindows",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]),
        // The scenarios of the window key filter, and the images of the snapshot tests.
        tests(
            "BifrostWindows",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostKeyboard",
                "BifrostSessions", "BifrostReviews", "BifrostSettings", "BifrostDictation",
                "BifrostChat", "BifrostDailyUpdate",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [.copy("UI/Scenarios"), .copy("Fixtures/Snapshots")]),
        // The files of the stores of the Electron app for the tests of the one-time import.
        tests(
            "BifrostApp",
            [
                "BifrostFoundation", "BifrostLayout", "BifrostLook", "BifrostKeyboard",
                "BifrostSessions", "BifrostLive", "BifrostReviews", "BifrostSettings",
                "BifrostDictation", "BifrostChat", "BifrostWindows", "BifrostHealth",
                "BifrostDailyUpdate",
            ],
            resources: [.copy("Services/Import/Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
