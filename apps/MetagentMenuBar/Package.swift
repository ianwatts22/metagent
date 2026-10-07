// swift-tools-version: 6.0

import PackageDescription

// The SwiftUI app, Sparkle, and their tests are macOS-only. On Linux the
// package builds just MetagentCore and the headless `metagent` CLI/MCP helper.
#if os(macOS)
let platformDependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/sparkle-project/Sparkle.git",
        exact: "2.9.4"
    )
]
let appProducts: [Product] = [
    .executable(name: "MetagentMenuBar", targets: ["MetagentMenuBar"])
]
let appTargets: [Target] = [
    .executableTarget(
        name: "MetagentMenuBar",
        dependencies: [
            "MetagentCore",
            .product(name: "Sparkle", package: "Sparkle")
        ],
        path: "Sources",
        exclude: [
            "MetagentCore",
            "MetagentCLI",
            "CLinuxShims",
            "LinuxSQLite3"
        ],
        resources: [
            .process("Resources")
        ]
    ),
    .testTarget(
        name: "MetagentMenuBarTests",
        dependencies: ["MetagentMenuBar"],
        path: "Tests/MetagentMenuBarTests"
    )
]
let coreDependencies: [Target.Dependency] = []
let platformTargets: [Target] = []
let coreTestDependencies: [Target.Dependency] = []
#else
let platformDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    .package(url: "https://github.com/swiftlang/swift-toolchain-sqlite.git", from: "1.0.0")
]
let appProducts: [Product] = []
let appTargets: [Target] = []
// Linux has no SDK SQLite3 or CryptoKit module: re-export a bundled SQLite
// under the same module name and use swift-crypto, so the helper links into a
// single static binary.
let coreDependencies: [Target.Dependency] = [
    "SQLite3",
    "CLinuxShims",
    .product(name: "Crypto", package: "swift-crypto")
]
let coreTestDependencies: [Target.Dependency] = [
    "SQLite3",
    .product(name: "Crypto", package: "swift-crypto")
]
let platformTargets: [Target] = [
    .target(name: "CLinuxShims", path: "Sources/CLinuxShims"),
    .target(
        name: "SQLite3",
        dependencies: [.product(name: "SwiftToolchainCSQLite", package: "swift-toolchain-sqlite")],
        path: "Sources/LinuxSQLite3"
    )
]
#endif

let package = Package(
    name: "MetagentMenuBar",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "MetagentCore", targets: ["MetagentCore"]),
        .executable(name: "metagent", targets: ["MetagentCLI"])
    ] + appProducts,
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        )
    ] + platformDependencies,
    targets: [
        .target(
            name: "MetagentCore",
            dependencies: coreDependencies,
            path: "Sources/MetagentCore"
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
            dependencies: ["MetagentCore"] + coreTestDependencies,
            path: "Tests/MetagentCoreTests"
        ),
        .testTarget(
            name: "MetagentCLITests",
            dependencies: ["MetagentCLI"],
            path: "Tests/MetagentCLITests"
        )
    ] + appTargets + platformTargets
)
