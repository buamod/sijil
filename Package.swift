// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "copyz",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "CopyzCore", targets: ["CopyzCore"]),
    .library(name: "CopyzPaste", targets: ["CopyzPaste"]),
    .executable(name: "copyz", targets: ["CopyzApp"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
  ],
  targets: [
    .target(
      name: "CopyzCore",
      dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
    ),
    .target(
      name: "CopyzPaste",
      dependencies: ["CopyzCore"]
    ),
    .executableTarget(
      name: "CopyzApp",
      dependencies: ["CopyzCore", "CopyzPaste"]
    ),
    .testTarget(
      name: "CopyzCoreTests",
      dependencies: ["CopyzCore", "CopyzPaste"]
    ),
    // App-layer logic is where the wiring bugs live: a setting that is stored
    // but never applied, a service that half-connects. Testing it needs the
    // executable target's code, which SwiftPM cannot import directly, so the
    // app logic lives in the target and is exercised through `@testable`.
    .testTarget(
      name: "CopyzAppTests",
      dependencies: ["CopyzApp", "CopyzCore", "CopyzPaste"]
    ),
  ]
)