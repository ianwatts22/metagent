// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MetagentMenuBar",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .executable(name: "MetagentMenuBar", targets: ["MetagentMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "MetagentMenuBar",
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
