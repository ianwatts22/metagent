import Foundation
import Logging
import MCP

/// Preserves request concurrency while ensuring each JSON-RPC response reaches
/// stdout as one uninterrupted byte sequence.
///
/// MCP's `StdioTransport` uses nonblocking writes. When a large response is
/// only partially written, it awaits before retrying; actor reentrancy can then
/// let another response write into the middle of the first one. This wrapper
/// queues complete `send` operations so only one enters the SDK transport at a
/// time.
actor SerializingStdioTransport: Transport {
    nonisolated let logger: Logger

    private let transport: StdioTransport
    private let messages: AsyncThrowingStream<Data, Error>
    private var sendTail: Task<Void, Never>?

    static func wrapping(_ transport: StdioTransport) async -> SerializingStdioTransport {
        let messages = await transport.receive()
        return SerializingStdioTransport(
            transport: transport,
            messages: messages
        )
    }

    private init(
        transport: StdioTransport,
        messages: AsyncThrowingStream<Data, Error>
    ) {
        self.transport = transport
        self.messages = messages
        logger = transport.logger
    }

    func connect() async throws {
        try await transport.connect()
    }

    func disconnect() async {
        let finalSend = sendTail
        await finalSend?.value
        await transport.disconnect()
    }

    func send(_ data: Data) async throws {
        let priorSend = sendTail
        let transport = self.transport
        let operation = Task<Void, Error> {
            await priorSend?.value
            try await transport.send(data)
        }
        sendTail = Task {
            _ = try? await operation.value
        }
        try await operation.value
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        messages
    }
}
