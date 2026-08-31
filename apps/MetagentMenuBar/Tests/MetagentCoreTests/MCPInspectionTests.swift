import Darwin
import Foundation
import XCTest
@testable import MetagentCore

final class MCPInspectionTests: XCTestCase {
    private var initialization: [String: Any] {
        ["protocolVersion": "2025-11-25", "serverInfo": ["name": "Fixture", "version": "1"],
         "capabilities": ["tools": [:]], "instructions": "Untrusted **description**"]
    }

    private func tool(_ name: String) -> [String: Any] {
        ["name": name, "description": "Description", "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]]],
         "outputSchema": ["type": "object"]]
    }

    func testInitializationPaginationAndMetadataOnlyRequests() throws {
        let session = MCPInspectionSession()
        var sent: [[String: Any]] = []
        let result = try session.inspect(send: { sent.append($0) }, receive: { id in
            switch id {
            case 1: return self.initialization
            case 2: return ["tools": [self.tool("first")], "nextCursor": "opaque"]
            default: return ["tools": [self.tool("second")]]
            }
        })
        XCTAssertEqual(sent.compactMap { $0["method"] as? String }, ["initialize", "notifications/initialized", "tools/list", "tools/list"])
        XCTAssertEqual((sent[3]["params"] as? [String: String])?["cursor"], "opaque")
        XCTAssertEqual(result.tools.map(\.name), ["first", "second"])
        XCTAssertEqual(result.instructions, "Untrusted **description**")
        XCTAssertTrue(result.tools[0].inputSchema.contains("query"))
        XCTAssertNotNil(result.tools[0].outputSchema)
    }

    func testNoToolsCapabilityDoesNotIssueList() throws {
        var sent: [String] = []
        var initResult = initialization
        initResult["capabilities"] = [:] as [String: Any]
        let result = try MCPInspectionSession().inspect(send: { sent.append($0["method"] as? String ?? "") }, receive: { _ in initResult })
        XCTAssertEqual(sent, ["initialize", "notifications/initialized"])
        XCTAssertTrue(result.tools.isEmpty)
    }

    func testNestedSchemasStayCompactAndOversizedSchemasFailWithoutPartialSnapshot() throws {
        var nested: [String: Any] = ["enum": Array(repeating: "value", count: 2_000)]
        for _ in 0..<80 { nested = ["properties": ["child": nested]] }
        let tool: [String: Any] = ["name": "nested", "inputSchema": nested]
        let result = try MCPInspectionSession().inspect(send: { _ in }, receive: { id in
            id == 1 ? self.initialization : ["tools": [tool]]
        })
        let schema = try XCTUnwrap(result.tools.first?.inputSchema)
        XCTAssertLessThan(schema.utf8.count, 32 * 1_024, "Indentation must not amplify compact server metadata")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let oversized: [String: Any] = ["name": "oversized", "inputSchema": ["description": String(repeating: "x", count: 257 * 1_024)]]
        XCTAssertThrowsError(try MCPInspectionSession().inspect(send: { _ in }, receive: { id in
            id == 1 ? self.initialization : ["tools": [oversized]]
        })) { XCTAssertEqual($0 as? MCPInspectionError, .outputLimit) }
    }

    func testUnsupportedProtocolAndMalformedToolFailClosed() {
        var wrongVersion = initialization
        wrongVersion["protocolVersion"] = "2099-01-01"
        XCTAssertThrowsError(try MCPInspectionSession().inspect(send: { _ in }, receive: { _ in wrongVersion }))
        XCTAssertThrowsError(try MCPInspectionSession().inspect(send: { _ in }, receive: { id in
            id == 1 ? self.initialization : ["tools": [["name": "missing-schema"]]]
        }))
    }

    func testPaginationCycleToolLimitAndDuplicateNamesFailClosed() {
        XCTAssertThrowsError(try MCPInspectionSession().inspect(send: { _ in }, receive: { id in
            id == 1 ? self.initialization : ["tools": [], "nextCursor": "again"]
        })) { XCTAssertEqual($0 as? MCPInspectionError, .paginationLimit) }
        XCTAssertThrowsError(try MCPInspectionSession(timeout: 1, maximumTools: 1).inspect(send: { _ in }, receive: { id in
            id == 1 ? self.initialization : ["tools": [self.tool("one"), self.tool("two")]]
        }))
        XCTAssertThrowsError(try MCPInspectionSession().inspect(send: { _ in }, receive: { id in
            id == 1 ? self.initialization : ["tools": [self.tool("same"), self.tool("same")]]
        }))
    }

    func testCancellationBeforeStartAndBetweenPages() {
        let cancelled = MCPInspectionSession()
        cancelled.cancel()
        XCTAssertThrowsError(try cancelled.inspect(send: { _ in XCTFail("Sent after cancellation") }, receive: { _ in [:] }))
        let midway = MCPInspectionSession()
        XCTAssertThrowsError(try midway.inspect(send: { _ in }, receive: { id in
            if id == 1 { return self.initialization }
            midway.cancel()
            return ["tools": [], "nextCursor": "next"]
        })) { XCTAssertEqual($0 as? MCPInspectionError, .cancelled) }
    }

    func testConfigurationUsesOnlyExplicitEnvironmentAndNeverExpandsShell() throws {
        let data = try JSONSerialization.data(withJSONObject: ["enabled": true, "transport": [
            "type": "stdio", "command": "/bin/echo", "args": ["$(touch /tmp/do-not-run)", "--secret=fixture"],
            "env": ["EXPLICIT_TOKEN": "fixture-secret"], "env_vars": []
        ]])
        let config = try MCPInspectionSession.parseConfiguration(data,
            environment: ["HOME": "/tmp", "PATH": "/bin", "AMBIENT_TOKEN": "never-forward"], directory: "/tmp")
        XCTAssertEqual(config.arguments.first, "$(touch /tmp/do-not-run)")
        XCTAssertNil(config.environment["AMBIENT_TOKEN"])
        XCTAssertEqual(config.environment["EXPLICIT_TOKEN"], "fixture-secret")
        XCTAssertEqual(config.argumentCount, 2)
    }

    func testDisabledUnsupportedAndMalformedConfigurationNeverLaunches() throws {
        let configurations: [[String: Any]] = [
            ["enabled": false, "transport": ["type": "stdio", "command": "/bin/echo"]],
            ["enabled": "yes", "transport": ["type": "stdio", "command": "/bin/echo"]],
            ["transport": ["type": "streamable_http", "url": "https://example.invalid?token=secret"]],
            ["transport": ["type": "stdio", "command": "/bin/echo", "env_vars": ["SECRET"]]],
            ["transport": ["type": "stdio", "command": "/bin/echo", "env_vars": "SECRET"]],
            ["transport": ["type": "stdio", "command": "/bin/echo", "cwd": 123]],
            ["transport": ["type": "stdio", "command": "/bin/echo", "args": "--secret"]],
            ["transport": ["type": "stdio", "command": "/bin/echo", "env": ["BAD": 123]]]
        ]
        for configuration in configurations {
            XCTAssertThrowsError(try MCPInspectionSession.parseConfiguration(
                JSONSerialization.data(withJSONObject: configuration), environment: [:], directory: "/tmp"
            ))
        }
    }

    func testRealFixtureProtocolAndServerRequestsCannotInvokeClientCapabilities() throws {
        let responses: [[String: Any]] = [
            ["jsonrpc": "2.0", "method": "sampling/createMessage", "id": "denied", "params": [:]],
            ["jsonrpc": "2.0", "id": 1, "result": initialization],
            ["jsonrpc": "2.0", "id": 2, "result": ["tools": [tool("fixture")]]]
        ]
        let snapshot = try MCPInspectionSession().inspect(fixture(responses: responses))
        XCTAssertEqual(snapshot.tools.map(\.name), ["fixture"])
    }

    func testUncorrelatedMalformedAndServerErrorOutputIsSafe() throws {
        for response: [String: Any] in [
            ["jsonrpc": "2.0", "id": 42, "result": initialization],
            ["jsonrpc": "2.0", "id": true, "result": initialization],
            ["jsonrpc": "2.0", "id": 1, "error": ["code": -32000, "message": "TOKEN=fixture-secret"]]
        ] {
            XCTAssertThrowsError(try MCPInspectionSession().inspect(fixture(responses: [response]))) {
                XCTAssertFalse($0.localizedDescription.contains("fixture-secret"))
            }
        }
        XCTAssertThrowsError(try MCPInspectionSession().inspect(shell("printf 'not json\\n'")))
    }

    func testTimeoutAndOutputLimitAreBounded() {
        let start = ContinuousClock.now
        XCTAssertThrowsError(try MCPInspectionSession(timeout: 0.15).inspect(shell("sleep 30"))) {
            XCTAssertEqual($0 as? MCPInspectionError, .timedOut)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertThrowsError(try MCPInspectionSession(timeout: 2, maximumBytes: 1_024).inspect(shell("/usr/bin/yes fixture >&2"))) {
            XCTAssertEqual($0 as? MCPInspectionError, .outputLimit)
        }
    }

    func testServerThatNeverReadsInputCannotBlockCancellationDeadline() throws {
        let request = ["jsonrpc": "2.0", "id": String(repeating: "x", count: 60_000), "method": "roots/list"]
        let configuration = try fixture(responses: [request, request, request])
        let start = ContinuousClock.now
        XCTAssertThrowsError(try MCPInspectionSession(timeout: 0.2).inspect(configuration)) {
            XCTAssertEqual($0 as? MCPInspectionError, .timedOut)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testFinalResponseFollowedImmediatelyByEOFIsAccepted() throws {
        let initialized = try json(["jsonrpc": "2.0", "id": 1, "result": initialization])
        let listed = try json(["jsonrpc": "2.0", "id": 2, "result": ["tools": [tool("final")]]])
        let script = "read -r first; printf '%s\\n' '\(initialized)'; read -r notification; read -r request; printf '%s\\n' '\(listed)'"
        let result = try MCPInspectionSession().inspect(shell(script))
        XCTAssertEqual(result.tools.map(\.name), ["final"])
    }

    func testClosedOutputAndPartialJSONFailPromptlyInsteadOfSpinning() {
        for script in ["printf '{'; exec 1>&-; sleep 30", "exec 1>&-; sleep 30"] {
            let start = ContinuousClock.now
            XCTAssertThrowsError(try MCPInspectionSession(timeout: 2).inspect(shell(script)))
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        }
    }

    func testConfigurationCommandFixtureUsesExactArgumentsAndNoAmbientSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex-fixture")
        let script = """
        #!/bin/sh
        [ "$1" = mcp ] && [ "$2" = get ] && [ "$3" = fixture ] && [ "$4" = --json ] || exit 1
        [ -z "$AMBIENT_TOKEN" ] || exit 2
        [ "$CODEX_HOME" = /tmp/fixture-codex-home ] || exit 3
        printf '%s' '{"enabled":true,"transport":{"type":"stdio","command":"/bin/echo","args":[]}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let configuration = try MCPInspectionSession().loadCodexConfiguration(name: "fixture", executable: executable,
            environment: ["PATH": "/bin", "AMBIENT_TOKEN": "secret", "CODEX_HOME": "/tmp/fixture-codex-home"], directory: directory.path)
        XCTAssertEqual(configuration.executable, "/bin/echo")
        XCTAssertNil(configuration.environment["AMBIENT_TOKEN"])
        XCTAssertNil(configuration.environment["CODEX_HOME"])
        XCTAssertThrowsError(try MCPInspectionSession().loadCodexConfiguration(name: "fixture\0suffix", executable: executable,
            environment: ["PATH": "/bin", "CODEX_HOME": "/tmp/fixture-codex-home"], directory: directory.path)) {
            XCTAssertEqual($0 as? MCPInspectionError, .unavailableConfiguration)
        }
    }

    func testCancellationStopsOwnedDescendantProcessGroup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child-pid")
        let session = MCPInspectionSession(timeout: 5)
        defer { session.cancel() }
        let finished = expectation(description: "cancelled")
        let outcome = InspectionOutcome()
        let configuration = shell("sleep 30 & child=$!; printf '%s' \"$child\" > '\(pidFile.path)'; wait")
        DispatchQueue.global().async {
            do {
                _ = try session.inspect(configuration)
            } catch {
                outcome.set(error as? MCPInspectionError)
            }
            finished.fulfill()
        }
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var parsed: Int32?
        while parsed == nil, ContinuousClock.now < readyDeadline {
            parsed = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init)
            if parsed == nil { usleep(10_000) }
        }
        let child = try XCTUnwrap(parsed)
        session.cancel()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(outcome.value, .cancelled)
        let reapingDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while kill(child, 0) == 0, ContinuousClock.now < reapingDeadline { usleep(10_000) }
        XCTAssertEqual(kill(child, 0), -1, "Owned child must not remain running after cancellation")
        XCTAssertEqual(errno, ESRCH)
    }

    private func fixture(responses: [[String: Any]]) throws -> MCPInspectionConfiguration {
        let lines = try responses.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let escaped = lines.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        return shell("printf '%s\\n' \(escaped); sleep 30")
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            .replacingOccurrences(of: "'", with: "'\\''")
    }

    private func shell(_ script: String) -> MCPInspectionConfiguration {
        MCPInspectionConfiguration(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"], directory: "/tmp")
    }
}

private final class InspectionOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: MCPInspectionError?
    var value: MCPInspectionError? { lock.withLock { failure } }
    func set(_ value: MCPInspectionError?) { lock.withLock { failure = value } }
}
