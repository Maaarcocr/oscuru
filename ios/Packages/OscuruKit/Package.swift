// swift-tools-version: 6.2
import PackageDescription

// OscuruCore is pure Swift (Foundation only) and also builds and tests on Linux: the editing
// state, the colour pipeline's tables, statistics, saved filters, and the agent loop.
// OscuruEngine (Core Image) and OscuruScripting (JavaScriptCore) exist only on Apple platforms.
var products: [Product] = [
    .library(name: "OscuruCore", targets: ["OscuruCore"]),
]
var targets: [Target] = [
    .target(name: "OscuruCore"),
    .testTarget(name: "OscuruCoreTests", dependencies: ["OscuruCore"]),
]

#if !os(Linux)
products.append(.library(name: "OscuruEngine", targets: ["OscuruEngine"]))
products.append(.library(name: "OscuruScripting", targets: ["OscuruScripting"]))
targets.append(.target(name: "OscuruEngine", dependencies: ["OscuruCore"], swiftSettings: [.swiftLanguageMode(.v5)]))
targets.append(.target(name: "OscuruScripting", dependencies: ["OscuruCore"], swiftSettings: [.swiftLanguageMode(.v5)]))
targets.append(.testTarget(name: "OscuruEngineTests", dependencies: ["OscuruEngine"], swiftSettings: [.swiftLanguageMode(.v5)]))
targets.append(.testTarget(name: "OscuruScriptingTests", dependencies: ["OscuruScripting"], swiftSettings: [.swiftLanguageMode(.v5)]))
#endif

let package = Package(
    name: "OscuruKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
