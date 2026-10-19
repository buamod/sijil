// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "sijil",
  // macOS 15 is the *deployment* target: what the app runs on. Compiling needs a
  // newer SDK, because the panel uses SwiftUI's `glassEffect`, which only exists in
  // the macOS 26 SDK. Those are different things — setting this to v26 would build
  // the tests for macOS 26 and make them unrunnable on a macOS 15 machine, which
  // is exactly the mistake CI caught on its first run.
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "SijilCore", targets: ["SijilCore"]),
    .library(name: "SijilPaste", targets: ["SijilPaste"]),
    .executable(name: "sijil", targets: ["SijilApp"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
  ],
  targets: [
    .target(
      name: "SijilCore",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
    ),
    .target(
      name: "SijilPaste",
      dependencies: ["SijilCore"]
    ),
    .executableTarget(
      name: "SijilApp",
      dependencies: ["SijilCore", "SijilPaste"]
    ),
    .testTarget(
      name: "SijilCoreTests",
      dependencies: ["SijilCore", "SijilPaste"]
    ),
    // App-layer logic is where the wiring bugs live: a setting that is stored
    // but never applied, a service that half-connects. Testing it needs the
    // executable target's code, which SwiftPM cannot import directly, so the
    // app logic lives in the target and is exercised through `@testable`.
    .testTarget(
      name: "SijilAppTests",
      dependencies: ["SijilApp", "SijilCore", "SijilPaste"]
    ),
  ]
)
