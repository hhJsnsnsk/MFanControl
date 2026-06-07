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
            path: "src/MFanControlShared",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "MFanControlApp",
            dependencies: ["MFanControlShared", "MFanControlHelperCore"],
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
            dependencies: ["MFanControlShared", "MFanControlHelperCore"],
            path: "src/MFanControlCLI/Sources"
        ),
        .executableTarget(
            name: "MFanControlHelper",
            dependencies: ["MFanControlShared", "MFanControlHelperCore"],
            path: "src/MFanControlHelper/Daemon",
            sources: ["DaemonMain.swift"]
        ),
        .target(
            name: "MFanControlHelperCore",
            dependencies: ["MFanControlShared"],
            path: "src/MFanControlHelper",
            exclude: ["Resources"],
            sources: [
                "Daemon/FanControlDaemon.swift",
                "Daemon/FanControlXPCService.swift",
                "IPC/ServiceProtocol.swift",
                "IPC/XPCHost.swift",
                "SMC/SmcBridge.swift",
                "SMC/SMCIOKitBridge.swift",
                "SMCKeys/KeyCatalog.swift"
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "MFanControlSharedTests",
            dependencies: ["MFanControlShared"],
            path: "tests/unit"
        ),
        .testTarget(
            name: "MFanControlIntegrationTests",
            dependencies: ["MFanControlApp", "MFanControlHelperCore", "MFanControlCLI", "MFanControlShared"],
            path: "tests/integration"
        )
    ]
)
