// swift-tools-version: 5.9
import PackageDescription

// The rendering engine on its own, without Expo or UIKit, so its tests run with `swift test` on a Mac.
// Sources/OscuruEngineCore is a symlink to ../ios/Engine: the same files the app compiles.
let package = Package(
  name: "OscuruEngineCore",
  platforms: [.iOS("16.4"), .macOS(.v13)],
  products: [.library(name: "OscuruEngineCore", targets: ["OscuruEngineCore"])],
  targets: [
    .target(name: "OscuruEngineCore", path: "Sources/OscuruEngineCore"),
    .testTarget(name: "OscuruEngineCoreTests", dependencies: ["OscuruEngineCore"], path: "Tests/OscuruEngineCoreTests"),
  ]
)
