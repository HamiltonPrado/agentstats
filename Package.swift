// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentStats",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentStats",
            path: "Sources/AgentStats",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "AgentStatsTests",
            dependencies: ["AgentStats"],
            path: "Tests/AgentStatsTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
