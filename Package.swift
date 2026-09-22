// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AEMMonitor",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AEMMonitor",
            path: "Sources/AEMMonitor",
            exclude: ["Info.plist"]
        )
    ]
)
