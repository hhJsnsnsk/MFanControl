// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFanControl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MFanControlApp", targets: ["MFanControlApp"]),
        .executable(name: "MFanControlCLI", targets: ["MFanControlCLI"]),
        .executable(name: "MFanControlHelper", targets: ["MFanControlHelper"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MFanControlShared",
            path: "src/MFanControlShared"
        ),
        .target(
            name: "MFanControlApp",
            dependencies: ["MFanControlShared"],
            path: "src/MFanControlApp",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "MFanControlCLI",
            dependencies: ["MFanControlShared"],
            path: "src/MFanControlCLI/Sources"
        ),
        .executableTarget(
            name: "MFanControlHelper",
            dependencies: ["MFanControlShared"],
            path: "src/MFanControlHelper/Daemon",
            resources: [
                .copy("../Resources")
            ]
        ),
        .testTarget(
            name: "MFanControlSharedTests",
            dependencies: ["MFanControlShared"],
            path: "tests/unit"
        ),
        .testTarget(
            name: "MFanControlIntegrationTests",
            dependencies: ["MFanControlApp", "MFanControlHelper", "MFanControlCLI", "MFanControlShared"],
            path: "tests/integration"
        )
    ]
)
