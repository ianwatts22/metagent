// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentToolsMenuBar",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .executable(name: "AgentToolsMenuBar", targets: ["AgentToolsMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "AgentToolsMenuBar",
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
