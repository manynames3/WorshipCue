// swift-tools-version: 6.1
import PackageDescription

let package = Package(name: "WorshipCueRemote", platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "WorshipCueRemote", targets: ["WorshipCueRemote"])],
    dependencies: [.package(path: "../../reference/WorshipCueCore")],
    targets: [.target(name: "WorshipCueRemote", dependencies: ["WorshipCueCore"]),
              .testTarget(name: "WorshipCueRemoteTests", dependencies: ["WorshipCueRemote"])])
