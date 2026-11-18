// swift-tools-version:5.9
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
        )
    ],
    swiftLanguageVersions: [.v5]
)
