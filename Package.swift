// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sidebrief",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "SidebriefApp", targets: ["SidebriefApp"]),
        .library(name: "SidebriefCore", targets: ["SidebriefCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SidebriefCore",
            path: "macOS",
            exclude: ["App", "Resources"],
            sources: ["Features", "Services", "Models", "Stores"]
        ),
        .executableTarget(
            name: "SidebriefApp",
            dependencies: ["SidebriefCore"],
            path: "macOS/App"
        ),
        .testTarget(
            name: "SidebriefTests",
            dependencies: ["SidebriefCore"],
            path: "tests"
        )
    ]
)
