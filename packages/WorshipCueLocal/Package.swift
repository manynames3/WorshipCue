// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "WorshipCueLocal",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "WorshipCueLocal", targets: ["WorshipCueLocal"]),
               .executable(name: "InkChecks", targets: ["InkChecks"])],
    dependencies: [
        .package(path: "../../reference/WorshipCueCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(name: "WorshipCueLocal", dependencies: [
            .product(name: "WorshipCueCore", package: "WorshipCueCore"),
            .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "InkChecks", dependencies: ["WorshipCueLocal", "WorshipCueCore"]),
        .testTarget(name: "WorshipCueLocalTests", dependencies: ["WorshipCueLocal"])
    ]
)
