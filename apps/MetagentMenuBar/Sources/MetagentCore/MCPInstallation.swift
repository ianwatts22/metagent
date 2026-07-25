import Foundation
import Darwin

public enum MCPSetupOperation: String, Codable, Sendable {
    case install
    case status
    case remove
}

public enum MCPSetupOutcome: String, Codable, Sendable {
    case preview
    case unchanged
    case changed
    case blocked
}

public enum MCPSetupConfigurationState: String, Codable, Sendable {
    case missing
    case matches
    case differs
    case disabled
    case differentScope = "different_scope"
    case unavailable
}

public enum MCPDirectVerificationState: String, Codable, Sendable {
    case verified
    case failed
    case notRun = "not_run"
}

public struct MCPSetupReport: Codable, Equatable, Sendable {
    public let client: MCPClient
    public let operation: MCPSetupOperation
    public let outcome: MCPSetupOutcome
    public let serverName: String
    public let applyRequested: Bool
    public let changed: Bool
    public let configurationState: MCPSetupConfigurationState
    public let expectedCommand: String
    public let expectedArguments: [String]
    public let managementCommand: [String]?
    public let directVerification: MCPDirectVerificationState
    public let detail: String
    public let clientRestartRequired: Bool
    public let runtimeCaveat: String

    public init(
        client: MCPClient,
        operation: MCPSetupOperation,
        outcome: MCPSetupOutcome,
        serverName: String,
        applyRequested: Bool,
        changed: Bool,
        configurationState: MCPSetupConfigurationState,
        expectedCommand: String,
        expectedArguments: [String],
        managementCommand: [String]?,
        directVerification: MCPDirectVerificationState,
        detail: String,
        clientRestartRequired: Bool,
        runtimeCaveat: String
    ) {
        self.client = client
        self.operation = operation
        self.outcome = outcome
        self.serverName = serverName
        self.applyRequested = applyRequested
        self.changed = changed
        self.configurationState = configurationState
        self.expectedCommand = expectedCommand
        self.expectedArguments = expectedArguments
        self.managementCommand = managementCommand
        self.directVerification = directVerification
        self.detail = detail
        self.clientRestartRequired = clientRestartRequired
        self.runtimeCaveat = runtimeCaveat
    }
}

public struct MCPCommandResult: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let timedOut: Bool

    public init(
        status: Int32,
        standardOutput: Data = Data(),
        standardError: Data = Data(),
        timedOut: Bool = false
    ) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

public protocol MCPCommandExecuting {
    func run(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> MCPCommandResult
}

public struct MCPSystemCommandExecutor: MCPCommandExecuting {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> MCPCommandResult {
        let result = try runSubprocess(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout
        )
        return MCPCommandResult(
            status: result.status,
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            timedOut: result.timedOut
        )
    }
}

public protocol MCPStdioVerifying {
    func verify(executable: URL) -> MCPDirectVerificationState
}

public struct MCPSystemStdioVerifier: MCPStdioVerifying {
    public init() {}

    public func verify(executable: URL) -> MCPDirectVerificationState {
        verifyMetagentStdioInteractively(executable: executable)
    }
}

public extension MetagentCore {
    static let managedMCPServerName = "metagent"

    static let mcpRuntimeCaveat =
        "This verifies configuration and the server's stdio protocol directly. A client restart or new session is still required before loaded, connected, or invoked state can be observed."

    static func currentExecutableURL(
        argumentZero: String = CommandLine.arguments[0],
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL {
        if let bundleExecutable = Bundle.main.executableURL {
            return bundleExecutable.resolvingSymlinksInPath().standardizedFileURL
        }
        return URL(fileURLWithPath: argumentZero, relativeTo: currentDirectory)
            .absoluteURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static func commandLineExecutable(
        named name: String,
        environmentOverride: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let candidate = firstExecutableCandidate(
            named: name,
            environmentOverride: environmentOverride,
            extraCandidates: [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/\(name)").path,
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)"
            ],
            environment: environment,
            requireAbsolutePaths: true
        ) else {
            throw MCPSetupError("\(name) executable not found")
        }
        return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().standardizedFileURL
    }

    static func manageMCPSetup(
        client: MCPClient,
        operation: MCPSetupOperation,
        apply: Bool = false,
        metagentExecutable: URL,
        clientExecutable: URL,
        executor: any MCPCommandExecuting,
        stdioVerifier: any MCPStdioVerifying = MCPSystemStdioVerifier()
    ) throws -> MCPSetupReport {
        let expectedExecutable = metagentExecutable
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let expectedArguments = ["mcp", "--stdio"]
        let existing = try inspectMCPConfiguration(
            client: client,
            clientExecutable: clientExecutable,
            executor: executor
        )
        let initialState = configurationState(
            existing,
            client: client,
            expectedExecutable: expectedExecutable,
            expectedArguments: expectedArguments
        )

        switch operation {
        case .status:
            let verification = stdioVerifier.verify(executable: expectedExecutable)
            return setupReport(
                client: client,
                operation: operation,
                outcome: .unchanged,
                apply: false,
                changed: false,
                configurationState: initialState,
                expectedExecutable: expectedExecutable,
                managementCommand: nil,
                verification: verification,
                detail: statusDetail(
                    configurationState: initialState,
                    verification: verification
                )
            )

        case .install:
            let command = installCommand(
                client: client,
                clientExecutable: clientExecutable,
                metagentExecutable: expectedExecutable
            )
            guard apply else {
                return setupReport(
                    client: client,
                    operation: operation,
                    outcome: .preview,
                    apply: false,
                    changed: false,
                    configurationState: initialState,
                    expectedExecutable: expectedExecutable,
                    managementCommand: command.display,
                    verification: .notRun,
                    detail: installPreviewDetail(initialState)
                )
            }
            if [.differs, .disabled, .differentScope].contains(initialState) {
                return setupReport(
                    client: client,
                    operation: operation,
                    outcome: .blocked,
                    apply: true,
                    changed: false,
                    configurationState: initialState,
                    expectedExecutable: expectedExecutable,
                    managementCommand: command.display,
                    verification: .notRun,
                    detail: installBlockedDetail(initialState, client: client)
                )
            }

            var changed = false
            if initialState == .missing {
                try requireSuccessful(
                    executor.run(
                        executable: clientExecutable,
                        arguments: command.arguments,
                        standardInput: nil,
                        timeout: 30
                    ),
                    action: "\(client.displayName) MCP installation"
                )
                changed = true
            }
            let verifiedConfiguration = try inspectMCPConfiguration(
                client: client,
                clientExecutable: clientExecutable,
                executor: executor
            )
            let finalState = configurationState(
                verifiedConfiguration,
                client: client,
                expectedExecutable: expectedExecutable,
                expectedArguments: expectedArguments
            )
            guard finalState == .matches else {
                throw MCPSetupError("\(client.displayName) did not report the expected metagent configuration after installation")
            }
            let verification = stdioVerifier.verify(executable: expectedExecutable)
            return setupReport(
                client: client,
                operation: operation,
                outcome: changed ? .changed : .unchanged,
                apply: true,
                changed: changed,
                configurationState: finalState,
                expectedExecutable: expectedExecutable,
                managementCommand: command.display,
                verification: verification,
                detail: changed
                    ? "Installed and verified through \(client.displayName)'s supported MCP CLI."
                    : "The expected configuration was already installed; no change was made."
            )

        case .remove:
            let command = removeCommand(client: client, clientExecutable: clientExecutable)
            guard apply else {
                return setupReport(
                    client: client,
                    operation: operation,
                    outcome: .preview,
                    apply: false,
                    changed: false,
                    configurationState: initialState,
                    expectedExecutable: expectedExecutable,
                    managementCommand: command.display,
                    verification: .notRun,
                    detail: removePreviewDetail(initialState, client: client)
                )
            }
            if initialState == .differentScope {
                return setupReport(
                    client: client,
                    operation: operation,
                    outcome: .blocked,
                    apply: true,
                    changed: false,
                    configurationState: initialState,
                    expectedExecutable: expectedExecutable,
                    managementCommand: command.display,
                    verification: .notRun,
                    detail: "Claude resolved metagent from a local or project scope. Guided removal only owns the user-scoped entry and will not mutate this entry."
                )
            }
            guard initialState != .missing else {
                return setupReport(
                    client: client,
                    operation: operation,
                    outcome: .unchanged,
                    apply: true,
                    changed: false,
                    configurationState: .missing,
                    expectedExecutable: expectedExecutable,
                    managementCommand: command.display,
                    verification: .notRun,
                    detail: "No metagent configuration exists; no change was made."
                )
            }
            try requireSuccessful(
                executor.run(
                    executable: clientExecutable,
                    arguments: command.arguments,
                    standardInput: nil,
                    timeout: 30
                ),
                action: "\(client.displayName) MCP removal"
            )
            let finalConfiguration = try inspectMCPConfiguration(
                client: client,
                clientExecutable: clientExecutable,
                executor: executor
            )
            if client == .claude {
                guard finalConfiguration?.scope != .user else {
                    throw MCPSetupError("Claude still reports a user-scoped metagent configuration after removal")
                }
            } else {
                guard finalConfiguration == nil else {
                    throw MCPSetupError("Codex still reports a metagent configuration after removal")
                }
            }
            let finalState: MCPSetupConfigurationState =
                finalConfiguration == nil ? .missing : .differentScope
            return setupReport(
                client: client,
                operation: operation,
                outcome: .changed,
                apply: true,
                changed: true,
                configurationState: finalState,
                expectedExecutable: expectedExecutable,
                managementCommand: command.display,
                verification: .notRun,
                detail: finalState == .missing
                    ? "Removed only the MCP entry named metagent through \(client.displayName)'s supported MCP CLI."
                    : "Removed the user-scoped metagent entry. A separate local or project-scoped Claude entry remains unchanged."
            )
        }
    }
}

private struct MCPConfiguredCommand: Equatable {
    let executable: String
    let arguments: [String]
    let enabled: Bool
    let scope: MCPConfiguredScope
}

private enum MCPConfiguredScope: Equatable {
    case user
    case local
    case project
    case unspecified
    case unknown
}

private struct MCPManagementCommand {
    let executable: URL
    let arguments: [String]

    var display: [String] {
        [executable.path] + arguments
    }
}

private struct CodexMCPGetResponse: Decodable {
    struct Transport: Decodable {
        let type: String
        let command: String?
        let args: [String]?
    }

    let enabled: Bool?
    let transport: Transport
}

private func inspectMCPConfiguration(
    client: MCPClient,
    clientExecutable: URL,
    executor: any MCPCommandExecuting
) throws -> MCPConfiguredCommand? {
    let arguments = client == .codex
        ? ["mcp", "get", MetagentCore.managedMCPServerName, "--json"]
        : ["mcp", "get", MetagentCore.managedMCPServerName]
    let result = try executor.run(
        executable: clientExecutable,
        arguments: arguments,
        standardInput: nil,
        timeout: 20
    )
    if result.status != 0 {
        let combined = outputText(result.standardOutput) + "\n" + outputText(result.standardError)
        if combined.localizedCaseInsensitiveContains("No MCP server") {
            return nil
        }
        throw MCPSetupError(
            combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(client.displayName) could not inspect the metagent MCP configuration"
                : combined.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    switch client {
    case .codex:
        let response = try JSONDecoder().decode(CodexMCPGetResponse.self, from: result.standardOutput)
        guard response.transport.type == "stdio", let command = response.transport.command else {
            return MCPConfiguredCommand(
                executable: "",
                arguments: [],
                enabled: response.enabled ?? true,
                scope: .unspecified
            )
        }
        return MCPConfiguredCommand(
            executable: command,
            arguments: response.transport.args ?? [],
            enabled: response.enabled ?? true,
            scope: .unspecified
        )
    case .claude:
        let text = outputText(result.standardOutput)
        guard let command = value(after: "Command:", in: text) else {
            throw MCPSetupError("Claude returned an unreadable metagent MCP configuration")
        }
        guard let scopeValue = value(after: "Scope:", in: text) else {
            throw MCPSetupError("Claude did not identify the scope of the metagent MCP configuration")
        }
        let arguments = value(after: "Args:", in: text)?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? []
        return MCPConfiguredCommand(
            executable: command,
            arguments: arguments,
            enabled: true,
            scope: claudeScope(scopeValue)
        )
    }
}

private func configurationState(
    _ configured: MCPConfiguredCommand?,
    client: MCPClient,
    expectedExecutable: URL,
    expectedArguments: [String]
) -> MCPSetupConfigurationState {
    guard let configured else { return .missing }
    if client == .claude && configured.scope != .user {
        return .differentScope
    }
    guard configured.enabled else { return .disabled }
    let configuredURL = URL(fileURLWithPath: configured.executable)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    return configuredURL.path == expectedExecutable.path
        && configured.arguments == expectedArguments
        ? .matches
        : .differs
}

private func claudeScope(_ value: String) -> MCPConfiguredScope {
    let normalized = value.lowercased()
    if normalized.contains("user config") { return .user }
    if normalized.contains("local config") { return .local }
    if normalized.contains("project config") { return .project }
    return .unknown
}

private func installCommand(
    client: MCPClient,
    clientExecutable: URL,
    metagentExecutable: URL
) -> MCPManagementCommand {
    let arguments: [String]
    switch client {
    case .codex:
        arguments = [
            "mcp", "add", MetagentCore.managedMCPServerName, "--",
            metagentExecutable.path, "mcp", "--stdio"
        ]
    case .claude:
        arguments = [
            "mcp", "add", "--scope", "user", MetagentCore.managedMCPServerName, "--",
            metagentExecutable.path, "mcp", "--stdio"
        ]
    }
    return MCPManagementCommand(executable: clientExecutable, arguments: arguments)
}

private func removeCommand(
    client: MCPClient,
    clientExecutable: URL
) -> MCPManagementCommand {
    let arguments = client == .codex
        ? ["mcp", "remove", MetagentCore.managedMCPServerName]
        : ["mcp", "remove", MetagentCore.managedMCPServerName, "--scope", "user"]
    return MCPManagementCommand(executable: clientExecutable, arguments: arguments)
}

private func verifyMetagentStdioInteractively(
    executable: URL
) -> MCPDirectVerificationState {
    let messages: [[String: Any]] = [
        [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "metagent-installer", "version": "1"]
            ]
        ],
        [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:]
        ],
        [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [:]
        ]
    ]
    let process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = executable
    process.arguments = ["mcp", "--stdio"]
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    do {
        let input = try messages.reduce(into: Data()) { data, message in
            data.append(try JSONSerialization.data(withJSONObject: message))
            data.append(Data([0x0A]))
        }
        try process.run()
        inputPipe.fileHandleForWriting.write(input)

        var pending = Data()
        var initialized = false
        var listedTools = false
        let outputDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        let errorDescriptor = errorPipe.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !(initialized && listedTools) {
            var pollDescriptors = [
                pollfd(fd: outputDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorDescriptor, events: Int16(POLLIN), revents: 0)
            ]
            let pollResult = pollDescriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), 250)
            }
            guard pollResult >= 0 else { break }
            guard pollResult > 0 else {
                if !process.isRunning { break }
                continue
            }
            if pollDescriptors[1].revents & Int16(POLLIN) != 0 {
                _ = errorPipe.fileHandleForReading.availableData
            }
            guard pollDescriptors[0].revents & Int16(POLLIN) != 0 else {
                if !process.isRunning { break }
                continue
            }
            let data = outputPipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard let response = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    continue
                }
                if (response["id"] as? Int) == 1 && response["result"] != nil {
                    initialized = true
                }
                if (response["id"] as? Int) == 2,
                   let result = response["result"] as? [String: Any],
                   result["tools"] is [[String: Any]] {
                    listedTools = true
                }
            }
        }
        try? inputPipe.fileHandleForWriting.close()
        stopMCPVerificationProcess(process)
        return initialized && listedTools ? .verified : .failed
    } catch {
        try? inputPipe.fileHandleForWriting.close()
        stopMCPVerificationProcess(process)
        return .failed
    }
}

private func stopMCPVerificationProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let terminationDeadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < terminationDeadline {
        usleep(20_000)
    }
    guard process.isRunning else { return }
    Darwin.kill(process.processIdentifier, SIGKILL)
    let killDeadline = Date().addingTimeInterval(1)
    while process.isRunning && Date() < killDeadline {
        usleep(20_000)
    }
}

private func setupReport(
    client: MCPClient,
    operation: MCPSetupOperation,
    outcome: MCPSetupOutcome,
    apply: Bool,
    changed: Bool,
    configurationState: MCPSetupConfigurationState,
    expectedExecutable: URL,
    managementCommand: [String]?,
    verification: MCPDirectVerificationState,
    detail: String
) -> MCPSetupReport {
    MCPSetupReport(
        client: client,
        operation: operation,
        outcome: outcome,
        serverName: MetagentCore.managedMCPServerName,
        applyRequested: apply,
        changed: changed,
        configurationState: configurationState,
        expectedCommand: expectedExecutable.path,
        expectedArguments: ["mcp", "--stdio"],
        managementCommand: managementCommand,
        directVerification: verification,
        detail: detail,
        clientRestartRequired: apply && changed,
        runtimeCaveat: MetagentCore.mcpRuntimeCaveat
    )
}

private func installPreviewDetail(_ state: MCPSetupConfigurationState) -> String {
    switch state {
    case .missing:
        "Preview only. Apply to install a user-scoped metagent MCP configuration."
    case .matches:
        "The expected metagent MCP configuration is already installed; applying would be idempotent."
    case .differs:
        "A different metagent configuration exists. Apply will not overwrite it."
    case .disabled:
        "The expected Codex entry exists but is disabled. Apply will not treat it as installed or silently replace it."
    case .differentScope:
        "Claude resolved metagent from a local or project scope. Guided installation will not overwrite or shadow it."
    case .unavailable:
        "The client CLI is unavailable, so no configuration change can be planned."
    }
}

private func installBlockedDetail(
    _ state: MCPSetupConfigurationState,
    client: MCPClient
) -> String {
    switch state {
    case .disabled:
        "The Codex metagent entry is disabled. Codex has no supported enable command, so remove it explicitly and rerun guided installation."
    case .differentScope:
        "Claude resolved metagent from a local or project scope. Guided installation only owns the user scope and will not overwrite or shadow this entry."
    default:
        "A different metagent configuration already exists. Remove it explicitly before installing this executable through \(client.displayName)."
    }
}

private func removePreviewDetail(
    _ state: MCPSetupConfigurationState,
    client: MCPClient
) -> String {
    switch state {
    case .missing:
        "No metagent configuration exists; applying this operation would be a no-op."
    case .differentScope:
        "Claude resolved a local or project-scoped metagent entry. Guided removal will not mutate it because it only owns user scope."
    default:
        "Preview only. Apply to remove only the \(client == .claude ? "user-scoped " : "")MCP entry named metagent."
    }
}

private func statusDetail(
    configurationState: MCPSetupConfigurationState,
    verification: MCPDirectVerificationState
) -> String {
    let configuration = switch configurationState {
    case .missing: "Not configured"
    case .matches: "Configured with this executable"
    case .differs: "Configured with a different command"
    case .disabled: "Configured but disabled"
    case .differentScope: "Configured in a local or project scope, not the guided user scope"
    case .unavailable: "Client CLI unavailable"
    }
    let stdio = verification == .verified
        ? "direct stdio verification passed"
        : "direct stdio verification failed"
    return "\(configuration); \(stdio)."
}

private func requireSuccessful(_ result: MCPCommandResult, action: String) throws {
    guard !result.timedOut, result.status == 0 else {
        let detail = outputText(result.standardError).trimmingCharacters(in: .whitespacesAndNewlines)
        throw MCPSetupError(
            detail.isEmpty
                ? "\(action) failed\(result.timedOut ? " because it timed out" : " with status \(result.status)")"
                : "\(action) failed: \(detail)"
        )
    }
}

private func outputText(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? ""
}

private func value(after label: String, in text: String) -> String? {
    text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix(label) }
        .map { String($0.dropFirst(label.count)).trimmingCharacters(in: .whitespaces) }
}

private struct MCPSetupError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
