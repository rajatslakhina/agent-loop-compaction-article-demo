// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionCompactionKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SessionCompaction", targets: ["SessionCompaction"])
    ],
    targets: [
        .target(name: "SessionCompaction"),
        .testTarget(name: "SessionCompactionTests", dependencies: ["SessionCompaction"])
    ]
)
