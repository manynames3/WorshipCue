// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorshipCueCore",
    platforms: [.iOS("16.0"), .macOS(.v13)],
    products: [.library(name: "WorshipCueCore", targets: ["WorshipCueCore"])],
    targets: [
        .target(name: "WorshipCueCore"),
        .testTarget(name: "WorshipCueCoreTests", dependencies: ["WorshipCueCore"])
    ]
)
