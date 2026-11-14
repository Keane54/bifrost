// swift-tools-version: 6.0
// The speech helper of Bifrost. scripts/build-dictation.ts builds it.
import Foundation
import PackageDescription

// The linker puts Info.plist into the __TEXT,__info_plist section. The helper has no bundle, so the
// Speech framework reads the usage texts and the bundle ID from that section.
let plist = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appendingPathComponent("Sources/bifrost-dictation/Info.plist").path

let package = Package(
  name: "bifrost-dictation",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "bifrost-dictation",
      path: "Sources/bifrost-dictation",
      exclude: ["Info.plist"],
      swiftSettings: [.swiftLanguageMode(.v5)],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", plist,
        ])
      ]
    )
  ]
)
