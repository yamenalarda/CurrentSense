// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CurrentSenseCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CurrentSenseCore", targets: ["CurrentSenseCore"])],
    targets: [
        .target(name: "CurrentSenseCore"),
        .testTarget(name: "CurrentSenseCoreTests", dependencies: ["CurrentSenseCore"])
    ]
)
