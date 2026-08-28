import Darwin
import Foundation
import Logging
import MCP

/// Event-driven MCP stdio transport with serialized response writes.
///
/// The SDK's `StdioTransport` puts stdin in nonblocking mode and checks it every
/// 10 milliseconds. That is useful for a generic transport, but it keeps every
/// idle Metagent helper waking about 100 times per second. `FileHandle` delivers
/// a readability event only when stdin has data or closes, so an idle helper can
/// sleep while retaining MCP's newline-delimited framing.
///
/// Response writes stay serialized and nonblocking, so client backpressure
/// neither interleaves JSON-RPC frames nor pins a cooperative executor thread.
actor SerializingStdioTransport: Transport {
    nonisolated let logger = Logger(
        label: "metagent.mcp.stdio",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private let input: FileHandle
    private let output: FileHandle
    private let outputFileDescriptor: Int32
    private let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let framer = NewlineMessageFramer()
    private let onReadEvent: (@Sendable () -> Void)?
    private var isConnected = false
    private var originalOutputFlags: Int32?
    private var sendTail: Task<Void, Error>?
    private var pendingWrites: [UUID: Task<Void, Error>] = [:]

    init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        onReadEvent: (@Sendable () -> Void)? = nil
    ) {
        self.input = input
        self.output = output
        outputFileDescriptor = output.fileDescriptor
        self.onReadEvent = onReadEvent

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        messages = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {
        guard !isConnected else { return }
        let flags = fcntl(outputFileDescriptor, F_GETFL)
        guard flags >= 0,
              fcntl(outputFileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0
        else {
            throw MCPError.transportError(POSIXError(.EIO))
        }
        originalOutputFlags = flags
        isConnected = true

        let continuation = self.continuation
        let framer = self.framer
        let onReadEvent = self.onReadEvent
        input.readabilityHandler = { handle in
            onReadEvent?()
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                if framer.finish() {
                    continuation.finish()
                }
                return
            }

            for message in framer.append(data) {
                continuation.yield(message)
            }
        }
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        input.readabilityHandler = nil
        let writes = Array(pendingWrites.values)
        pendingWrites.removeAll()
        sendTail = nil
        writes.forEach { $0.cancel() }
        for write in writes {
            _ = await write.result
        }
        if let originalOutputFlags {
            _ = fcntl(outputFileDescriptor, F_SETFL, originalOutputFlags)
            self.originalOutputFlags = nil
        }
        if framer.finish() {
            continuation.finish()
        }
    }

    func send(_ data: Data) async throws {
        guard isConnected else { throw MCPError.connectionClosed }
        var framed = data
        framed.append(0x0A)
        let prior = sendTail
        let fileDescriptor = outputFileDescriptor
        let id = UUID()
        let operation = Task.detached(priority: .utility) {
            if let prior {
                _ = await prior.result
            }
            try Task.checkCancellation()
            try await Self.writeAll(framed, to: fileDescriptor)
        }
        sendTail = operation
        pendingWrites[id] = operation
        defer { pendingWrites[id] = nil }
        do {
            try await operation.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPError.transportError(error)
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        messages
    }

    private nonisolated static func writeAll(_ data: Data, to fileDescriptor: Int32) async throws {
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(
                    fileDescriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try await FileDescriptorWriteWaiter(fileDescriptor: fileDescriptor).wait()
                continue
            }
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }
}

/// Suspends one nonblocking write until the descriptor has capacity. Cancellation
/// tears down the dispatch source and resumes the awaiting task immediately.
private final class FileDescriptorWriteWaiter: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let lock = NSLock()
    private var source: DispatchSourceWrite?
    private var continuation: CheckedContinuation<Void, Error>?
    private var isFinished = false

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !isFinished else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let source = DispatchSource.makeWriteSource(
                    fileDescriptor: fileDescriptor,
                    queue: .global(qos: .utility)
                )
                self.source = source
                self.continuation = continuation
                source.setEventHandler { [weak self] in
                    self?.finish()
                }
                lock.unlock()
                source.resume()
            }
        } onCancel: {
            finish(error: CancellationError())
        }
    }

    private func finish(error: Error? = nil) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let source = self.source
        let continuation = self.continuation
        self.source = nil
        self.continuation = nil
        lock.unlock()

        source?.cancel()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

/// `FileHandle` invokes its readability callback outside the transport actor.
/// Keep the small framing buffer behind a lock so disconnect and EOF cannot
/// race with delivery of the last complete message.
private final class NewlineMessageFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var isFinished = false

    func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return [] }

        pending.append(data)
        var messages: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let message = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if !message.isEmpty {
                messages.append(message)
            }
        }
        return messages
    }

    /// Returns true only for the caller that transitions the stream to EOF.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return false }
        isFinished = true
        pending.removeAll(keepingCapacity: false)
        return true
    }
}
