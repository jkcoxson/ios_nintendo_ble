// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NintendoBLE",
    platforms: [.iOS(.v14), .macOS(.v13)],
    products: [.library(name: "NintendoBLE", targets: ["NintendoBLE"])],
    targets: [
        .target(name: "NintendoBLE"),
        .testTarget(name: "NintendoBLETests", dependencies: ["NintendoBLE"]),
    ]
)
