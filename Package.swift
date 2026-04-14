// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Core-Monitor-CLI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CoreMonitorKit", targets: ["CoreMonitorKit"]),
        .executable(name: "core-monitor", targets: ["CoreMonitorCLI"]),
        .executable(name: "core-monitor-helper", targets: ["CoreMonitorHelper"]),
        .executable(name: "core-monitor-bless-host", targets: ["CoreMonitorBlessHost"])
    ],
    targets: [
        .target(
            name: "CoreMonitorIPC",
            path: "Sources/CoreMonitorIPC"
        ),
        .target(
            name: "CoreMonitorKit",
            dependencies: ["CoreMonitorIPC"],
            path: "Sources/CoreMonitorKit"
        ),
        .executableTarget(
            name: "CoreMonitorCLI",
            dependencies: ["CoreMonitorKit"],
            path: "Sources/CoreMonitorCLI"
        ),
        .executableTarget(
            name: "CoreMonitorHelper",
            dependencies: ["CoreMonitorIPC"],
            path: "Sources/CoreMonitorHelper",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "BuildSupport/Generated/CoreMonitorHelper-Info.plist",
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__launchd_plist",
                    "-Xlinker", "BuildSupport/Generated/CoreMonitorHelper-Launchd.plist"
                ], .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "CoreMonitorBlessHost",
            dependencies: ["CoreMonitorIPC"],
            path: "Sources/CoreMonitorBlessHost",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
