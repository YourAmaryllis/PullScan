// swift-tools-version: 6.0
// Platform-independent PullScan logic, shared by the iOS app and its tests.
// Mirrors the Android classes of the same names; `swift test` runs on a Mac.
import PackageDescription

let package = Package(
    name: "PullScanCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PullScanCore", targets: ["PullScanCore"])],
    targets: [
        .target(name: "PullScanCore"),
        .testTarget(name: "PullScanCoreTests", dependencies: ["PullScanCore"]),
    ],
    swiftLanguageModes: [.v5]
)
