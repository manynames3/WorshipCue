// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "WorshipCueInk",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "WorshipCueInk", targets: ["WorshipCueInk"]),
        .executable(name: "FrameworkChecks", targets: ["FrameworkChecks"])
    ],
    dependencies: [.package(path: "../WorshipCueLocal")],
    targets: [
        .target(name: "WorshipCueInk", dependencies: ["WorshipCueLocal"]),
        .executableTarget(name: "FrameworkChecks", dependencies: ["WorshipCueInk", "WorshipCueLocal"])
    ]
)
