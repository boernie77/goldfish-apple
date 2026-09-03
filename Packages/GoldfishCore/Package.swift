// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GoldfishCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16)
    ],
    products: [
        .library(name: "GoldfishCore", targets: ["GoldfishCore"])
    ],
    targets: [
        .target(name: "GoldfishCore")
    ]
)
