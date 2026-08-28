import Foundation
import XCTest
@testable import MetagentCLI

final class SerializingStdioTransportTests: XCTestCase {
    func testIdleTransportDoesNotPollOpenInput() async throws {
        let input = Pipe()
        let output = Pipe()
        let counter = ReadEventCounter()
        let transport = SerializingStdioTransport(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            onReadEvent: { counter.increment() }
        )

        try await transport.connect()
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(counter.value, 0, "idle stdin should not cause read wakeups")

        await transport.disconnect()
        try input.fileHandleForWriting.close()
        try output.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
    }

    func testFramesMessagesAndFinishesWhenInputCloses() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = SerializingStdioTransport(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )
        let stream = await transport.receive()
        try await transport.connect()

        let received = Task { () -> [String] in
            var values: [String] = []
            do {
                for try await data in stream {
                    values.append(String(decoding: data, as: UTF8.self))
                }
            } catch {
                XCTFail("unexpected transport error: \(error)")
            }
            return values
        }

        input.fileHandleForWriting.write(Data("first\nsec".utf8))
        input.fileHandleForWriting.write(Data("ond\n".utf8))
        try input.fileHandleForWriting.close()

        let values = await received.value
        XCTAssertEqual(values, ["first", "second"])

        await transport.disconnect()
        try output.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
    }

    func testSerializesCompleteResponseWrites() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = SerializingStdioTransport(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )
        try await transport.connect()

        async let first: Void = transport.send(Data("first".utf8))
        async let second: Void = transport.send(Data("second".utf8))
        _ = try await (first, second)
        await transport.disconnect()
        try output.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(Set(lines), Set(["first", "second"]))
        XCTAssertEqual(lines.count, 2)

        try input.fileHandleForWriting.close()
        try output.fileHandleForReading.close()
    }

    func testDisconnectCancelsABackpressuredWrite() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = SerializingStdioTransport(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )
        try await transport.connect()

        let sending = Task {
            try await transport.send(Data(repeating: 0x78, count: 4 * 1_024 * 1_024))
        }
        try await Task.sleep(for: .milliseconds(50))
        await transport.disconnect()

        do {
            try await sending.value
            XCTFail("a backpressured write should be cancelled by disconnect")
        } catch is CancellationError {
            // Expected: disconnect must not wait for the client to resume reading.
        }

        try input.fileHandleForWriting.close()
        try output.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
    }
}

private final class ReadEventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
