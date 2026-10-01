import Foundation
import XCTest
@testable import MetagentCore

final class SkillUsageRecordDecoderTests: XCTestCase {
    func testPendingReadSurvivesDecoderInstancesWithoutAdvancingCursor() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-record-decoder")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/demo"))
        var state = UsageSourceState()
        state.offset = 2_048
        state.fileSize = 8_192
        state.fileIdentity = "source-identity"
        state.prefixFingerprint = "source-fingerprint"
        var cache: [String: ParsedSkillIdentity] = [:]
        var events: [ParsedUsageEvent] = []
        var runs: [ParsedAgentRun] = []
        let source = root.appendingPathComponent("session.jsonl").path

        func decode(_ type: String, _ payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "type": type, "timestamp": "2026-10-01T10:00:00Z", "payload": payload
            ])
            // A refresh continuation uses a fresh decoder with checkpointed state.
            SkillUsageRecordDecoder().parseLine(
                data, lineOffset: state.offset, sourcePath: source, state: &state,
                identityCache: &cache, events: &events, runs: &runs
            )
        }

        try decode("session_meta", ["id": "session", "cwd": root.path, "thread_source": "user"])
        try decode("turn_context", ["turn_id": "turn"])
        try decode("response_item", [
            "type": "function_call", "name": "exec_command", "call_id": "read",
            "arguments": ["cmd": "cat .agents/skills/demo/SKILL.md"]
        ])
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(state.pendingEvents["read"]?.count, 1)

        try decode("response_item", [
            "type": "function_call_output", "call_id": "read",
            "output": "---\nname: demo\ndescription: fixture\n---"
        ])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.sessionID, "session")
        XCTAssertEqual(events.first?.turnID, "turn")
        XCTAssertEqual(events.first?.cwd, root.path)
        XCTAssertEqual(events.first?.skill.name, "demo")
        XCTAssertTrue(state.pendingEvents.isEmpty)
        XCTAssertTrue(runs.isEmpty)
        XCTAssertEqual(state.offset, 2_048)
        XCTAssertEqual(state.fileSize, 8_192)
        XCTAssertEqual(state.fileIdentity, "source-identity")
        XCTAssertEqual(state.prefixFingerprint, "source-fingerprint")
    }

    func testIrrelevantAndMalformedRecordsDoNotMutateSession() {
        var state = UsageSourceState()
        state.sessionID = "existing-session"
        state.offset = 100
        var cache: [String: ParsedSkillIdentity] = [:]
        var events: [ParsedUsageEvent] = []
        var runs: [ParsedAgentRun] = []
        for record in ["not JSON", #"{"type":"event_msg","payload":{"type":"token_count"}}"#, "SKILL.md not JSON"] {
            SkillUsageRecordDecoder().parseLine(
                Data(record.utf8), lineOffset: 100, sourcePath: "/tmp/session.jsonl",
                state: &state, identityCache: &cache, events: &events, runs: &runs
            )
        }
        XCTAssertEqual(state.sessionID, "existing-session")
        XCTAssertEqual(state.offset, 100)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(runs.isEmpty)
        XCTAssertTrue(cache.isEmpty)
    }
}
