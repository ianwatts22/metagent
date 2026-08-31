import Darwin
import CoreFoundation
import Foundation

/// An ephemeral, approved configuration snapshot. Arguments and environment are never presentation data.
public struct MCPInspectionConfiguration: Sendable {
    public let executable: String
    public let argumentCount: Int
    let arguments: [String]
    let environment: [String: String]
    let directory: String

    init(executable: String, arguments: [String], environment: [String: String], directory: String) {
        self.executable = executable
        self.argumentCount = arguments.count
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }
}

public struct MCPInspectedTool: Identifiable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: String
    public let outputSchema: String?
    public var id: String { name }
}

public struct MCPInspectionSnapshot: Sendable {
    public let serverName: String
    public let serverVersion: String
    public let serverDescription: String?
    public let instructions: String?
    public let protocolVersion: String
    public let tools: [MCPInspectedTool]
    public let observedAt: Date
}

public enum MCPInspectionError: Error, LocalizedError, Equatable {
    case cancelled, timedOut, outputLimit, invalidResponse, serverFailed, unsupportedTransport
    case disabled, unavailableConfiguration, unsupportedEnvironment, missingExecutable, paginationLimit

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Inspection cancelled."
        case .timedOut: "Inspection timed out. The server process group was stopped."
        case .outputLimit: "The server exceeded the inspection output limit."
        case .invalidResponse: "The server returned an invalid or unsupported MCP response."
        case .serverFailed: "The server could not complete inspection. Raw server errors are hidden because they may contain secrets."
        case .unsupportedTransport: "This version inspects Codex stdio servers only. Remote HTTP and Claude inspection are not supported yet."
        case .disabled: "This server is disabled. Enable it in its client before inspecting."
        case .unavailableConfiguration: "The Codex user configuration could not be read. No server was started."
        case .unsupportedEnvironment: "This configuration requires an environment value that Metagent cannot safely resolve. No server was started."
        case .missingExecutable: "The configured executable is not available on Metagent’s PATH. No server was started."
        case .paginationLimit: "The server exceeded the inspection pagination limit. No partial inventory is shown."
        }
    }
}

/// One-shot metadata-only session. Call blocking operations off the main actor; cancel is thread-safe.
/// No disk cache, OAuth, tool invocation, subscriptions, or background refresh.
public final class MCPInspectionSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let timeout: TimeInterval
    let maximumBytes: Int
    let maximumPages: Int
    let maximumTools: Int

    public init() { timeout = 15; maximumBytes = 2 * 1_024 * 1_024; maximumPages = 20; maximumTools = 500 }

    init(timeout: TimeInterval, maximumBytes: Int = 2 * 1_024 * 1_024, maximumPages: Int = 20, maximumTools: Int = 500) {
        self.timeout = timeout
        self.maximumBytes = maximumBytes
        self.maximumPages = maximumPages
        self.maximumTools = maximumTools
    }

    public func cancel() { lock.withLock { cancelled = true } }

    func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw MCPInspectionError.cancelled }
    }

    /// Uses only the supported client configuration command, rooted at HOME rather than a project.
    public func loadCodexConfiguration(name: String) throws -> MCPInspectionConfiguration {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), name.utf8.count < 1_024 else {
            throw MCPInspectionError.unavailableConfiguration
        }
        let executable: URL
        do { executable = try codexExecutable() }
        catch { throw MCPInspectionError.unavailableConfiguration }
        let environment = ProcessInfo.processInfo.environment
        return try loadCodexConfiguration(name: name, executable: executable, environment: environment, directory: homeURL().path)
    }

    func loadCodexConfiguration(name: String, executable: URL, environment: [String: String], directory: String) throws -> MCPInspectionConfiguration {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), name.utf8.count < 1_024 else {
            throw MCPInspectionError.unavailableConfiguration
        }
        var clientEnvironment = Self.baseEnvironment(environment)
        if let codexHome = environment["CODEX_HOME"] {
            guard codexHome.hasPrefix("/"), !codexHome.contains("\0") else { throw MCPInspectionError.unavailableConfiguration }
            clientEnvironment["CODEX_HOME"] = codexHome
        }
        let configuration = MCPInspectionConfiguration(
            executable: executable.path, arguments: ["mcp", "get", name, "--json"],
            environment: clientEnvironment, directory: directory
        )
        let process = try MCPInspectionProcess(configuration: configuration, session: self)
        defer { process.stop() }
        let data = try process.readToEnd()
        guard process.successfulExit() else { throw MCPInspectionError.unavailableConfiguration }
        return try Self.parseConfiguration(data, environment: environment, directory: directory)
    }

    static func baseEnvironment(_ source: [String: String]) -> [String: String] {
        let allowed = Set(["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"])
        return source.filter { allowed.contains($0.key) }
    }

    static func parseConfiguration(_ data: Data, environment: [String: String], directory: String) throws -> MCPInspectionConfiguration {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transport = object["transport"] as? [String: Any] else {
            throw MCPInspectionError.unavailableConfiguration
        }
        if let enabled = object["enabled"], !(enabled is NSNull) {
            guard let number = enabled as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw MCPInspectionError.unavailableConfiguration
            }
            guard number.boolValue else { throw MCPInspectionError.disabled }
        }
        guard transport["type"] as? String == "stdio" else { throw MCPInspectionError.unsupportedTransport }
        guard let command = transport["command"] as? String, !command.isEmpty else { throw MCPInspectionError.unavailableConfiguration }
        let arguments: [String] = try Self.optional(transport["args"]) ?? []
        // No shell expansion, ambient secret lookup, or environment forwarding from the host process.
        let forwarded: [String] = try Self.optional(transport["env_vars"])
            ?? []
        guard forwarded.isEmpty else { throw MCPInspectionError.unsupportedEnvironment }
        var launchEnvironment = baseEnvironment(environment)
        if let raw = transport["env"], !(raw is NSNull) {
            guard let explicit = raw as? [String: String],
                  explicit.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
                throw MCPInspectionError.unsupportedEnvironment
            }
            launchEnvironment.merge(explicit, uniquingKeysWith: { _, configured in configured })
        }
        let executable: String
        if command.hasPrefix("/") { executable = command }
        else {
            guard !command.contains("/"), let found = firstExecutableCandidate(
                named: command, environmentOverride: nil, extraCandidates: [],
                environment: launchEnvironment, requireAbsolutePaths: true
            ) else { throw MCPInspectionError.missingExecutable }
            executable = found
        }
        guard fileManager.isExecutableFile(atPath: executable),
              !executable.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw MCPInspectionError.missingExecutable
        }
        let configuredDirectory: String? = try Self.optional(transport["cwd"])
        let cwd = configuredDirectory ?? directory
        guard cwd.hasPrefix("/"), !cwd.contains("\0") else { throw MCPInspectionError.unavailableConfiguration }
        return MCPInspectionConfiguration(executable: executable, arguments: arguments, environment: launchEnvironment, directory: cwd)
    }

    private static func optional<T>(_ value: Any?) throws -> T? {
        guard let value, !(value is NSNull) else { return nil }
        guard let typed = value as? T else { throw MCPInspectionError.unavailableConfiguration }
        return typed
    }

    public func inspect(_ configuration: MCPInspectionConfiguration) throws -> MCPInspectionSnapshot {
        let process = try MCPInspectionProcess(configuration: configuration, session: self)
        defer { process.stop() }
        return try inspect(send: process.send, receive: process.receive)
    }

    /// Kept transport-independent so protocol behavior is exercised without launching real MCPs.
    func inspect(send: ([String: Any]) throws -> Void, receive: (Int) throws -> [String: Any]) throws -> MCPInspectionSnapshot {
        try checkCancellation()
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:],
            "clientInfo": ["name": "metagent-inspector", "version": "1"]
        ]])
        let initialized = try receive(1)
        guard let version = initialized["protocolVersion"] as? String,
              ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version),
              let server = initialized["serverInfo"] as? [String: Any],
              let name = server["name"] as? String, let serverVersion = server["version"] as? String,
              let capabilities = initialized["capabilities"] as? [String: Any] else { throw MCPInspectionError.invalidResponse }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        var tools: [MCPInspectedTool] = []
        var cursor: String?
        var cursors = Set<String>()
        var names = Set<String>()
        if let toolsCapability = capabilities["tools"] {
            guard toolsCapability is [String: Any] else { throw MCPInspectionError.invalidResponse }
            for page in 0..<maximumPages {
                try checkCancellation()
                let id = page + 2
                try send(["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": cursor.map { ["cursor": $0] } ?? [:]])
                let response = try receive(id)
                guard let listed = response["tools"] as? [[String: Any]] else { throw MCPInspectionError.invalidResponse }
                guard tools.count + listed.count <= maximumTools else { throw MCPInspectionError.paginationLimit }
                for tool in listed {
                    try checkCancellation()
                    guard let name = tool["name"] as? String, !name.isEmpty, names.insert(name).inserted,
                          let schema = tool["inputSchema"] as? [String: Any] else { throw MCPInspectionError.invalidResponse }
                    let outputSchema: [String: Any]? = try Self.metadata(tool["outputSchema"])
                    let output = try outputSchema.map(Self.schemaJSON)
                    let description: String? = try Self.metadata(tool["description"])
                    tools.append(MCPInspectedTool(name: name, description: description,
                                                  inputSchema: try Self.schemaJSON(schema), outputSchema: output))
                }
                guard let next = response["nextCursor"] else { break }
                guard let next = next as? String, !next.isEmpty, cursors.insert(next).inserted,
                      page + 1 < maximumPages else { throw MCPInspectionError.paginationLimit }
                cursor = next
            }
        }
        try checkCancellation()
        return MCPInspectionSnapshot(serverName: name, serverVersion: serverVersion,
                                     serverDescription: try Self.metadata(server["description"]),
                                     instructions: try Self.metadata(initialized["instructions"]), protocolVersion: version,
                                     tools: tools, observedAt: Date())
    }

    private static func metadata<T>(_ value: Any?) throws -> T? {
        guard let value else { return nil }
        guard let typed = value as? T else { throw MCPInspectionError.invalidResponse }
        return typed
    }

    private static func schemaJSON(_ value: [String: Any]) throws -> String {
        // Pretty-print indentation can amplify a small nested schema into hundreds
        // of MiB. Keep compact JSON and reject oversized schemas, never truncate one
        // while presenting it as a complete tool contract.
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 256 * 1_024 else { throw MCPInspectionError.outputLimit }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Bounded, nonblocking stdio with an owned process group. Deliberately narrower than a general MCP client.
private final class MCPInspectionProcess {
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let session: MCPInspectionSession
    private let deadline: ContinuousClock.Instant
    private var pid: pid_t = 0
    private var pending = Data()
    private var bytes = 0
    private var exitStatus: Int32?
    private var outputEnded = false
    private var errorsEnded = false

    init(configuration: MCPInspectionConfiguration, session: MCPInspectionSession) throws {
        self.session = session
        deadline = ContinuousClock.now.advanced(by: .seconds(session.timeout))
        try session.checkCancellation()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw MCPInspectionError.serverFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw MCPInspectionError.serverFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        let descriptors = [(input.fileHandleForReading.fileDescriptor, STDIN_FILENO),
                           (output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
                           (errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)]
        for (source, target) in descriptors {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw MCPInspectionError.serverFailed }
        }
        guard posix_spawn_file_actions_addchdir(&actions, configuration.directory) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw MCPInspectionError.serverFailed }
        var args = ([configuration.executable] + configuration.arguments).map { strdup($0) }
        args.append(nil)
        defer { args.dropLast().forEach { free($0) } }
        var env = configuration.environment.map { strdup("\($0.key)=\($0.value)") }
        env.append(nil)
        defer { env.dropLast().forEach { free($0) } }
        guard posix_spawn(&pid, configuration.executable, &actions, &attributes, &args, &env) == 0 else {
            pid = 0
            throw MCPInspectionError.serverFailed
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                stop()
                throw MCPInspectionError.serverFailed
            }
        }
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            stop()
            throw MCPInspectionError.serverFailed
        }
    }

    deinit { stop() }

    func stop() {
        guard pid > 0 else { return }
        try? input.fileHandleForWriting.close()
        kill(-pid, SIGTERM)
        let cleanupDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        while isProcessGroupAlive(pid), ContinuousClock.now < cleanupDeadline { usleep(10_000) }
        if isProcessGroupAlive(pid) { kill(-pid, SIGKILL) }
        // The leader is not reaped before group cleanup, so its PID cannot be reused
        // by an unrelated process between observation and kill(-pid).
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        pid = 0
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }

    private func check() throws {
        try session.checkCancellation()
        guard ContinuousClock.now < deadline else { throw MCPInspectionError.timedOut }
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        guard data.count <= 64 * 1_024 else { throw MCPInspectionError.outputLimit }
        var offset = 0
        while offset < data.count {
            try check()
            let count = data.withUnsafeBytes { Darwin.write(input.fileHandleForWriting.fileDescriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && (errno == EAGAIN || errno == EINTR) { try pump() }
            else { throw MCPInspectionError.serverFailed }
        }
    }

    func receive(_ id: Int) throws -> [String: Any] {
        while true {
            try check()
            while let newline = pending.firstIndex(of: 0x0A) {
                try check()
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["jsonrpc"] as? String == "2.0" else { throw MCPInspectionError.invalidResponse }
                if object["method"] != nil {
                    // No client capabilities advertised: refuse server-initiated requests without executing them.
                    if let requestID = object["id"] {
                        try send(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32601, "message": "Unsupported by metadata inspector"]])
                    }
                    continue
                }
                guard let number = object["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue == Double(id) else { throw MCPInspectionError.invalidResponse }
                guard object["error"] == nil else { throw MCPInspectionError.serverFailed }
                guard let result = object["result"] as? [String: Any] else { throw MCPInspectionError.invalidResponse }
                return result
            }
            if outputEnded { throw MCPInspectionError.invalidResponse }
            try pump()
        }
    }

    func readToEnd() throws -> Data {
        try? input.fileHandleForWriting.close()
        while exitStatus == nil { try pump(allowExit: true) }
        // Drain remaining buffered pipe data after the process exits.
        try drain(output.fileHandleForReading.fileDescriptor, retaining: true)
        return pending
    }

    func successfulExit() -> Bool { exitStatus.map(subprocessExitStatus) == 0 }

    private func pump(allowExit: Bool = false) throws {
        try check()
        var descriptors = [pollfd(fd: outputEnded ? -1 : output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: errorsEnded ? -1 : errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
        let result = Darwin.poll(&descriptors, 2, 50)
        guard result >= 0 || errno == EINTR else { throw MCPInspectionError.serverFailed }
        for index in descriptors.indices where descriptors[index].revents & Int16(POLLIN | POLLHUP) != 0 {
            try drain(descriptors[index].fd, retaining: index == 0)
        }
        if exitStatus == nil {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
                exitStatus = info.si_code == CLD_EXITED ? info.si_status << 8 : info.si_status
            }
        }
        if exitStatus != nil && !allowExit && pending.isEmpty { throw MCPInspectionError.serverFailed }
    }

    private func drain(_ fd: Int32, retaining: Bool) throws {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            try check()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 && retaining { outputEnded = true }
            if count == 0 && !retaining { errorsEnded = true }
            if count < 0 && errno != EAGAIN && errno != EINTR { throw MCPInspectionError.serverFailed }
            guard count > 0 else { return }
            bytes += count
            guard bytes <= session.maximumBytes else { throw MCPInspectionError.outputLimit }
            if retaining { pending.append(contentsOf: buffer.prefix(count)) }
        }
    }
}
