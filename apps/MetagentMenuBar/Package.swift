// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MetagentMenuBar",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "MetagentCore", targets: ["MetagentCore"]),
        .executable(name: "MetagentMenuBar", targets: ["MetagentMenuBar"]),
        .executable(name: "metagent", targets: ["MetagentCLI"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            exact: "2.9.4"
        )
    ],
    targets: [
        .target(
            name: "MetagentCore",
            path: "Sources/MetagentCore"
        ),
        .executableTarget(
            name: "MetagentMenuBar",
            dependencies: [
                "MetagentCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
            dependencies: [
                "MetagentCore",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/MetagentCLI"
        ),
        .testTarget(
            name: "MetagentCoreTests",
            dependencies: ["MetagentCore"],
            path: "Tests/MetagentCoreTests"
        )
    ]
)
