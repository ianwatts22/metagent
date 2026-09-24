import Darwin
import Foundation
import MCP
import MetagentCore

/// Explicit, read-only standalone proof. No arbitrary tool-call surface is exposed.
enum NotionTransportProof {
    static func run(_ arguments: [String]) throws {
        guard arguments.count == 1 else { throw ProofCLIError.message("usage: metagent notion proof <start|finish|list>") }
        switch arguments[0] {
        case "start":
            let url = try blocking { try await NotionOAuthProof.start() }
            print("Open this URL in a browser and authorize the intended Notion workspace:")
            print(url.absoluteString)
            print("After redirect, run 'metagent notion proof finish' and paste the full callback URL when prompted.")
            print("The local callback page may show a connection error; copy its URL from the address bar.")
        case "finish":
            stderr("Paste the full callback URL, then press Return (input hidden on a terminal):")
            guard let input = hiddenLine(), let callback = URL(string: input) else {
                throw ProofCLIError.message("missing callback URL")
            }
            let connection = try blocking { try await NotionOAuthProof.finish(callback: callback) }
            print("Standalone Notion OAuth connection stored in macOS Keychain.")
            if let workspace = connection.workspaceID { print("Workspace ID: \(workspace)") }
        case "list":
            try blocking { try await listTools() }
        default:
            throw ProofCLIError.message("usage: metagent notion proof <start|finish|list>")
        }
    }

    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResult<T>()
        Task.detached {
            do { result.store(.success(try await body())) }
            catch { result.store(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.value().get()
    }

    private static func listTools() async throws {
        let connection = try await NotionOAuthProof.connection()
        let transport = HTTPClientTransport(endpoint: NotionOAuthProof.endpoint, streaming: false, requestModifier: { request in
            var request = request
            request.setValue("Bearer \(connection.accessToken)", forHTTPHeaderField: "Authorization")
            return request
        })
        let client = Client(name: "metagent-notion-proof", version: "1.0")
        try await client.connect(transport: transport)
        do {
            try await printToolInventory(client: client)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    private static func printToolInventory(client: Client) async throws {
        var names = Set<String>()
        var cursor: String?
        var complete = false
        for _ in 0..<20 {
            let page = try await client.listTools(cursor: cursor)
            guard names.count + page.tools.count <= 500 else { throw ProofCLIError.message("Notion tool inventory exceeded proof limit") }
            for tool in page.tools { names.insert(tool.name) }
            guard let next = page.nextCursor else { complete = true; break }
            cursor = next
        }
        guard complete else { throw ProofCLIError.message("Notion tool inventory exceeded 20 pages") }
        print("Independent Notion MCP tool names (\(names.count)):")
        for name in names.sorted() { print("  \(name)") }
        let nativeSkillNames = names.filter { $0.localizedCaseInsensitiveContains("skill") &&
            ($0.localizedCaseInsensitiveContains("upload") || $0.localizedCaseInsensitiveContains("download")) }
        print("Native skill upload/download candidates: \(nativeSkillNames.sorted().joined(separator: ", "))")
        if names.contains("notion-get-tool-access") {
            let access = try await client.callTool(name: "notion-get-tool-access", arguments: [:])
            guard access.isError != true else { throw ProofCLIError.message("Notion tool-access read failed") }
            for item in access.content {
                if case .text(let text, _, _) = item { print("Tool access: \(text)") }
            }
        }
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func hiddenLine() -> String? {
        var original = termios()
        let isTerminal = tcgetattr(STDIN_FILENO, &original) == 0
        if isTerminal {
            var hidden = original
            hidden.c_lflag &= ~tcflag_t(ECHO)
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &hidden)
        }
        defer {
            if isTerminal {
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
                stderr("")
            }
        }
        return readLine(strippingNewline: true)
    }
}

private enum ProofCLIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

private final class LockedResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?
    func store(_ value: Result<T, Error>) { lock.withLock { stored = value } }
    func value() -> Result<T, Error> { lock.withLock { stored! } }
}
