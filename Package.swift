// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoonGram",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "MoonGramCore", targets: ["MoonGramCore"])],
    targets: [
        .target(name: "MoonGramCore", path: "MoonGram/Core/Sources"),
        .testTarget(name: "MoonGramCoreTests", dependencies: ["MoonGramCore"], path: "Tests/MoonGramCoreTests")
    ]
)
