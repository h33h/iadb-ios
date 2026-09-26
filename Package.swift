// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ADBCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ADBCore", targets: ["ADBCore"]),
    ],
    targets: [
        .target(name: "ADBCore", path: "Sources/ADBCore"),
        .testTarget(name: "ADBCoreTests", dependencies: ["ADBCore"], path: "Tests/ADBCoreTests"),
    ]
)
