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
        XCTAssertFalse(executor.invocations.contains { $0.arguments.contains("other-server") })
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
        XCTAssertTrue(report.runtimeCaveat.contains("client restart"))
        XCTAssertTrue(report.runtimeCaveat.contains("connected"))
        XCTAssertTrue(report.runtimeCaveat.contains("invoked"))
    }

    private static let missingConfiguration = MCPCommandResult(
        status: 1,
        standardError: Data("No MCP server named 'metagent' found.".utf8)
    )

    private static func codexConfiguration(command: String) -> MCPCommandResult {
        MCPCommandResult(
            status: 0,
            standardOutput: Data("""
            {
              "name": "metagent",
              "transport": {
                "type": "stdio",
                "command": "\(command)",
                "args": ["mcp", "--stdio"]
              }
            }
            """.utf8)
        )
    }

    private static func claudeConfiguration(command: String) -> MCPCommandResult {
        MCPCommandResult(
            status: 0,
            standardOutput: Data("""
            metagent:
              Scope: User config (available in all your projects)
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
