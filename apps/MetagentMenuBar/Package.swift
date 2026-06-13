// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MetagentMenuBar",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .library(name: "MetagentCore", targets: ["MetagentCore"]),
        .executable(name: "MetagentMenuBar", targets: ["MetagentMenuBar"]),
        .executable(name: "metagent", targets: ["MetagentCLI"])
    ],
    targets: [
        .target(
            name: "MetagentCore",
            path: "Sources/MetagentCore"
        ),
        .executableTarget(
            name: "MetagentMenuBar",
            dependencies: ["MetagentCore"],
            path: "Sources",
            exclude: [
                "MetagentCore",
                "MetagentCLI"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "MetagentCLI",
            dependencies: ["MetagentCore"],
            path: "Sources/MetagentCLI"
        )
    ]
)
