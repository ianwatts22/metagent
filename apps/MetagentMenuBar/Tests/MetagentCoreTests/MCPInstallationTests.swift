import Foundation
import XCTest
@testable import MetagentCore

final class MCPInstallationTests: XCTestCase {
    func testInstallPreviewNeverMutatesClientConfiguration() throws {
        let executor = RecordingMCPExecutor { executable, arguments, _ in
            XCTAssertEqual(executable.path, "/tools/codex")
            XCTAssertEqual(arguments, ["mcp", "get", "metagent", "--json"])
            return Self.missingConfiguration
        }

        let report = try MetagentCore.manageMCPSetup(
            client: .codex,
            operation: .install,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/codex"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )

        XCTAssertEqual(report.outcome, .preview)
        XCTAssertEqual(report.configurationState, .missing)
        XCTAssertFalse(report.changed)
        XCTAssertFalse(report.clientRestartRequired)
        XCTAssertEqual(executor.invocations.count, 1)
        XCTAssertEqual(
            report.managementCommand,
            ["/tools/codex", "mcp", "add", "metagent", "--", "/tools/metagent", "mcp", "--stdio"]
        )
    }

    func testCodexInstallAppliesThroughCLIThenVerifiesConfigurationAndStdio() throws {
        var step = 0
        let executor = RecordingMCPExecutor { executable, arguments, input in
            defer { step += 1 }
            switch step {
            case 0:
                return Self.missingConfiguration
            case 1:
                XCTAssertEqual(executable.path, "/tools/codex")
                XCTAssertEqual(
                    arguments,
                    ["mcp", "add", "metagent", "--", "/tools/metagent", "mcp", "--stdio"]
                )
                return MCPCommandResult(status: 0)
            case 2:
                return Self.codexConfiguration(command: "/tools/metagent")
            default:
                XCTFail("unexpected command")
                return MCPCommandResult(status: 1)
            }
        }

        let report = try MetagentCore.manageMCPSetup(
            client: .codex,
            operation: .install,
            apply: true,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/codex"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )

        XCTAssertEqual(report.outcome, .changed)
        XCTAssertTrue(report.changed)
        XCTAssertEqual(report.configurationState, .matches)
        XCTAssertEqual(report.directVerification, .verified)
        XCTAssertTrue(report.clientRestartRequired)
        XCTAssertEqual(executor.invocations.count, 3)
    }

    func testInstallIsIdempotentWhenConfigurationAlreadyMatches() throws {
        var step = 0
        let executor = RecordingMCPExecutor { _, arguments, _ in
            defer { step += 1 }
            XCTAssertEqual(arguments, ["mcp", "get", "metagent", "--json"])
            return Self.codexConfiguration(command: "/tools/metagent")
        }

        let report = try MetagentCore.manageMCPSetup(
            client: .codex,
            operation: .install,
            apply: true,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/codex"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )

        XCTAssertEqual(report.outcome, .unchanged)
        XCTAssertFalse(report.changed)
        XCTAssertFalse(report.clientRestartRequired)
        XCTAssertEqual(executor.invocations.count, 2)
        XCTAssertFalse(executor.invocations.contains { $0.arguments.contains("add") })
    }

    func testInstallRefusesToOverwriteDifferentConfiguration() throws {
        let executor = RecordingMCPExecutor { _, _, _ in
            Self.codexConfiguration(command: "/older/metagent")
        }

        let report = try MetagentCore.manageMCPSetup(
            client: .codex,
            operation: .install,
            apply: true,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/codex"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )

        XCTAssertEqual(report.outcome, .blocked)
        XCTAssertEqual(report.configurationState, .differs)
        XCTAssertFalse(report.changed)
        XCTAssertEqual(executor.invocations.count, 1)
    }

    func testDisabledCodexEntryIsNotHealthyOrAnIdempotentInstall() throws {
        let executor = RecordingMCPExecutor { _, _, _ in
            Self.codexConfiguration(command: "/tools/metagent", enabled: false)
        }

        let status = try MetagentCore.manageMCPSetup(
            client: .codex,
            operation: .status,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/codex"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )
        let install = try MetagentCore.manageMCPSetup(
            client: .codex,
            operation: .install,
            apply: true,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/codex"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )

        XCTAssertEqual(status.configurationState, .disabled)
        XCTAssertTrue(status.detail.localizedCaseInsensitiveContains("disabled"))
        XCTAssertEqual(install.configurationState, .disabled)
        XCTAssertEqual(install.outcome, .blocked)
        XCTAssertFalse(install.changed)
        XCTAssertTrue(install.detail.contains("remove it explicitly"))
        XCTAssertFalse(executor.invocations.contains { $0.arguments.contains("add") })
    }

    func testClaudeInstallUsesUserScopeAndParsesOfficialGetOutput() throws {
        var step = 0
        let executor = RecordingMCPExecutor { executable, arguments, _ in
            defer { step += 1 }
            switch step {
            case 0:
                return Self.missingConfiguration
            case 1:
                XCTAssertEqual(executable.path, "/tools/claude")
                XCTAssertEqual(
                    arguments,
                    [
                        "mcp", "add", "--scope", "user", "metagent", "--",
                        "/tools/metagent", "mcp", "--stdio"
                    ]
                )
                return MCPCommandResult(status: 0)
            case 2:
                return Self.claudeConfiguration(command: "/tools/metagent")
            default:
                XCTFail("unexpected command")
                return MCPCommandResult(status: 1)
            }
        }

        let report = try MetagentCore.manageMCPSetup(
            client: .claude,
            operation: .install,
            apply: true,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/claude"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )

        XCTAssertEqual(report.configurationState, .matches)
        XCTAssertEqual(report.directVerification, .verified)
    }

    func testRemoveUsesOfficialCLIAndVerifiesOnlyNamedEntryIsGone() throws {
        var step = 0
        let executor = RecordingMCPExecutor { executable, arguments, _ in
            defer { step += 1 }
            switch step {
            case 0:
                return Self.claudeConfiguration(command: "/tools/metagent")
            case 1:
                XCTAssertEqual(executable.path, "/tools/claude")
                XCTAssertEqual(arguments, ["mcp", "remove", "metagent", "--scope", "user"])
                return MCPCommandResult(status: 0)
            default:
                return Self.missingConfiguration
            }
        }

        let report = try MetagentCore.manageMCPSetup(
            client: .claude,
            operation: .remove,
            apply: true,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/claude"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )

        XCTAssertEqual(report.outcome, .changed)
        XCTAssertEqual(report.configurationState, .missing)
        XCTAssertEqual(report.directVerification, .notRun)
        XCTAssertTrue(report.clientRestartRequired)
        XCTAssertFalse(executor.invocations.contains { $0.arguments.contains("other-server") })
    }

    func testClaudeLocalEntryBlocksUserScopedInstallAndRemoval() throws {
        let executor = RecordingMCPExecutor { _, _, _ in
            Self.claudeConfiguration(command: "/project/metagent", scope: "Local config (private to this project)")
        }

        let install = try MetagentCore.manageMCPSetup(
            client: .claude,
            operation: .install,
            apply: true,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/claude"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )
        let remove = try MetagentCore.manageMCPSetup(
            client: .claude,
            operation: .remove,
            apply: true,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/claude"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )

        XCTAssertEqual(install.configurationState, .differentScope)
        XCTAssertEqual(install.outcome, .blocked)
        XCTAssertEqual(remove.configurationState, .differentScope)
        XCTAssertEqual(remove.outcome, .blocked)
        XCTAssertFalse(executor.invocations.contains { $0.arguments.contains("add") })
        XCTAssertFalse(executor.invocations.contains { $0.arguments.contains("remove") })
    }

    func testClaudeRemovalCanRevealAndPreserveProjectScopedEntry() throws {
        var step = 0
        let executor = RecordingMCPExecutor { _, arguments, _ in
            defer { step += 1 }
            switch step {
            case 0:
                return Self.claudeConfiguration(command: "/tools/metagent")
            case 1:
                XCTAssertEqual(arguments, ["mcp", "remove", "metagent", "--scope", "user"])
                return MCPCommandResult(status: 0)
            default:
                return Self.claudeConfiguration(
                    command: "/project/metagent",
                    scope: "Project config (shared through .mcp.json)"
                )
            }
        }

        let report = try MetagentCore.manageMCPSetup(
            client: .claude,
            operation: .remove,
            apply: true,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/claude"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.verified)
        )

        XCTAssertEqual(report.outcome, .changed)
        XCTAssertEqual(report.configurationState, .differentScope)
        XCTAssertTrue(report.detail.contains("remains unchanged"))
        XCTAssertEqual(executor.invocations.filter { $0.arguments.contains("remove") }.count, 1)
    }

    func testStatusSeparatesConfigurationFromDirectProtocolVerification() throws {
        let executor = RecordingMCPExecutor { _, _, _ in
            Self.codexConfiguration(command: "/different/metagent")
        }

        let report = try MetagentCore.manageMCPSetup(
            client: .codex,
            operation: .status,
            metagentExecutable: URL(fileURLWithPath: "/tools/metagent"),
            clientExecutable: URL(fileURLWithPath: "/tools/codex"),
            executor: executor,
            stdioVerifier: StubMCPVerifier(.failed)
        )

        XCTAssertEqual(report.configurationState, .differs)
        XCTAssertEqual(report.directVerification, .failed)
        XCTAssertFalse(report.clientRestartRequired)
        XCTAssertTrue(report.runtimeCaveat.contains("client restart"))
        XCTAssertTrue(report.runtimeCaveat.contains("connected"))
        XCTAssertTrue(report.runtimeCaveat.contains("invoked"))
    }

    func testExecutableDiscoveryIgnoresRelativeOverrideAndPathEntries() throws {
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let relativeDirectoryName = ".metagent-relative-\(UUID().uuidString)"
        let relativeDirectory = currentDirectory.appendingPathComponent(relativeDirectoryName)
        let executable = relativeDirectory.appendingPathComponent("fake-mcp-client")
        try FileManager.default.createDirectory(
            at: relativeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: relativeDirectory) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        XCTAssertThrowsError(
            try MetagentCore.commandLineExecutable(
                named: "fake-mcp-client",
                environmentOverride: "TEST_MCP_CLIENT",
                environment: [
                    "TEST_MCP_CLIENT": "\(relativeDirectoryName)/fake-mcp-client",
                    "PATH": relativeDirectoryName
                ]
            )
        )
    }

    func testSystemStdioVerifierDrainsStderrAndBoundsStubbornShutdown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-stdio-verifier-\(UUID().uuidString)")
        let executable = root.appendingPathComponent("fake-metagent")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        #!/bin/sh
        head -c 262144 /dev/zero >&2
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{}}}'
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}'
        trap '' TERM
        while :; do :; done
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let startedAt = Date()
        let result = MCPSystemStdioVerifier().verify(executable: executable)

        XCTAssertEqual(result, .verified)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
    }

    private static let missingConfiguration = MCPCommandResult(
        status: 1,
        standardError: Data("No MCP server named 'metagent' found.".utf8)
    )

    private static func codexConfiguration(
        command: String,
        enabled: Bool = true
    ) -> MCPCommandResult {
        MCPCommandResult(
            status: 0,
            standardOutput: Data("""
            {
              "name": "metagent",
              "enabled": \(enabled),
              "transport": {
                "type": "stdio",
                "command": "\(command)",
                "args": ["mcp", "--stdio"]
              }
            }
            """.utf8)
        )
    }

    private static func claudeConfiguration(
        command: String,
        scope: String = "User config (available in all your projects)"
    ) -> MCPCommandResult {
        MCPCommandResult(
            status: 0,
            standardOutput: Data("""
            metagent:
              Scope: \(scope)
              Status: ✔ Connected
              Type: stdio
              Command: \(command)
              Args: mcp --stdio
              Environment:
            """.utf8)
        )
    }
}

private struct StubMCPVerifier: MCPStdioVerifying {
    let result: MCPDirectVerificationState

    init(_ result: MCPDirectVerificationState) {
        self.result = result
    }

    func verify(executable _: URL) -> MCPDirectVerificationState {
        result
    }
}

private final class RecordingMCPExecutor: MCPCommandExecuting {
    struct Invocation {
        let executable: URL
        let arguments: [String]
        let standardInput: Data?
    }

    private(set) var invocations: [Invocation] = []
    private let handler: (URL, [String], Data?) throws -> MCPCommandResult

    init(handler: @escaping (URL, [String], Data?) throws -> MCPCommandResult) {
        self.handler = handler
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        timeout _: TimeInterval
    ) throws -> MCPCommandResult {
        invocations.append(Invocation(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput
        ))
        return try handler(executable, arguments, standardInput)
    }
}
