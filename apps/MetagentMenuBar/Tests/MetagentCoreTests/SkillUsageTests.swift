import Darwin
import Foundation
import SQLite3
import XCTest
@testable import MetagentCore

final class SkillUsageTests: XCTestCase {
    func testParsesCodexFractionalAndWholeSecondTimestamps() {
        XCTAssertNotNil(MetagentCore.parseSkillUsageTimestamp("2026-07-19T12:00:00.000Z"))
        XCTAssertNotNil(MetagentCore.parseSkillUsageTimestamp("2026-07-19T12:00:00Z"))
    }

    func testIncrementalBackfillPreservesRepeatedReadsWithoutDoubleCountingRescans() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let localSkill = try fixture.makeSkill(
            at: "workspace/.agents/skills/test-skill",
            name: "test-skill"
        )
        let pluginSkill = try fixture.makeSkill(
            at: ".codex/plugins/cache/openai-curated-remote/coderabbit/1.1.4/skills/coderabbit-review",
            name: "code-review"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-test.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "session-1",
                "cwd": fixture.root.path
            ]),
            fixture.line(type: "turn_context", payload: [
                "turn_id": "turn-1",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "call-1", command: "sed -n '1,200p' \(localSkill.path)"),
            fixture.toolCall(callID: "call-2", command: "sed -n '1,200p' \(localSkill.path)"),
            fixture.toolCall(callID: "call-3", command: "sed -n '1,200p' \(pluginSkill.path)")
        ], to: rollout)

        let options = SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        )
        let first = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertTrue(first.snapshot.isBackfillComplete)
        XCTAssertEqual(first.invocationsAdded, 3)

        let local = try XCTUnwrap(first.snapshot.summaries.first { $0.skillName == "test-skill" })
        XCTAssertEqual(local.totalInvocations, 2)
        XCTAssertEqual(local.activeTurns, 1)
        XCTAssertEqual(local.distinctThreads, 1)
        XCTAssertEqual(local.repeatInvocations, 1)
        XCTAssertEqual(local.inferredInvocations, 2)

        let plugin = try XCTUnwrap(first.snapshot.summaries.first { $0.skillName == "coderabbit:code-review" })
        XCTAssertEqual(plugin.scope, "plugin")
        XCTAssertEqual(plugin.totalInvocations, 1)

        try fixture.append([
            fixture.line(type: "turn_context", payload: [
                "turn_id": "turn-2",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "call-4", command: "sed -n '1,200p' \(localSkill.path)")
        ], to: rollout)

        let second = try MetagentCore.refreshSkillUsage(options: options)
        let updated = try XCTUnwrap(second.snapshot.summaries.first { $0.skillName == "test-skill" })
        XCTAssertEqual(second.invocationsAdded, 1)
        XCTAssertEqual(updated.totalInvocations, 3)
        XCTAssertEqual(updated.activeTurns, 2)
        XCTAssertEqual(updated.repeatInvocations, 1)

        let third = try MetagentCore.refreshSkillUsage(options: options)
        XCTAssertEqual(third.invocationsAdded, 0)
        XCTAssertEqual(third.snapshot.totalInvocations, 4)
    }

    func testUsageAggregatesAcrossFrontmatterNameChangesAtOneCanonicalPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/renamed-skill",
            name: "old-name"
        )
        let firstRollout = fixture.sessions.appendingPathComponent("rollout-before-rename.jsonl")
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:00:00.000Z",
                type: "session_meta",
                payload: ["id": "rename-session", "cwd": fixture.root.path]
            ),
            fixture.line(
                timestamp: "2026-07-19T12:00:01.000Z",
                type: "turn_context",
                payload: ["turn_id": "rename-turn", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-before-rename", command: "cat \(skill.path)")
        ], to: firstRollout)
        _ = try MetagentCore.refreshSkillUsage(options: fixture.options)

        try "---\nname: new-name\ndescription: fixture\n---\n".write(
            to: skill,
            atomically: true,
            encoding: .utf8
        )
        let secondRollout = fixture.sessions.appendingPathComponent("rollout-after-rename.jsonl")
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:01:00.000Z",
                type: "session_meta",
                payload: ["id": "rename-session", "cwd": fixture.root.path]
            ),
            fixture.line(
                timestamp: "2026-07-19T12:01:01.000Z",
                type: "turn_context",
                payload: ["turn_id": "rename-turn", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-after-rename", command: "cat \(skill.path)")
        ], to: secondRollout)

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        let summary = try XCTUnwrap(summaries.first { $0.canonicalPath == skill.deletingLastPathComponent().path })
        XCTAssertEqual(summaries.filter { $0.canonicalPath == summary.canonicalPath }.count, 1)
        XCTAssertEqual(summary.skillName, "new-name")
        XCTAssertEqual(summary.totalInvocations, 2)
        XCTAssertEqual(summary.activeTurns, 1)
        XCTAssertEqual(summary.distinctThreads, 1)
        XCTAssertEqual(summary.repeatInvocations, 1)
    }

    func testPluginUsageAggregatesAcrossVersionedCachePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldSkill = try fixture.makeSkill(
            at: ".codex/plugins/cache/openai-curated/example-plugin/1.0.0/skills/example-skill",
            name: "old-name"
        )
        let newSkill = try fixture.makeSkill(
            at: ".codex/plugins/cache/openai-curated-remote/example-plugin/2.0.0/skills/example-skill",
            name: "new-name"
        )
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:00:00.000Z",
                type: "session_meta",
                payload: ["id": "plugin-session", "cwd": fixture.root.path]
            ),
            fixture.line(
                timestamp: "2026-07-19T12:00:01.000Z",
                type: "turn_context",
                payload: ["turn_id": "plugin-turn", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-old-plugin", command: "cat \(oldSkill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-old-plugin.jsonl"))
        _ = try MetagentCore.refreshSkillUsage(options: fixture.options)
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:01:00.000Z",
                type: "session_meta",
                payload: ["id": "plugin-session", "cwd": fixture.root.path]
            ),
            fixture.line(
                timestamp: "2026-07-19T12:01:01.000Z",
                type: "turn_context",
                payload: ["turn_id": "plugin-turn", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-new-plugin", command: "cat \(newSkill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-new-plugin.jsonl"))

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        let summary = try XCTUnwrap(summaries.first {
            $0.id == "plugin:openai-curated/example-plugin:example-skill"
        })
        XCTAssertEqual(summaries.filter { $0.id == summary.id }.count, 1)
        XCTAssertEqual(summary.skillName, "example-plugin:new-name")
        XCTAssertEqual(summary.canonicalPath, newSkill.deletingLastPathComponent().path)
        XCTAssertEqual(summary.totalInvocations, 2)
        XCTAssertEqual(summary.activeTurns, 1)
        XCTAssertEqual(summary.distinctThreads, 1)
        XCTAssertEqual(summary.repeatInvocations, 1)
    }

    func testPluginUsageKeepsSeparateMarketplacesDistinct() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let curated = try fixture.makeSkill(
            at: ".codex/plugins/cache/openai-curated/example-plugin/1.0.0/skills/example-skill",
            name: "curated-name"
        )
        let bundled = try fixture.makeSkill(
            at: ".codex/plugins/cache/openai-bundled/example-plugin/1.0.0/skills/example-skill",
            name: "bundled-name"
        )
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:00:00.000Z",
                type: "session_meta",
                payload: ["id": "marketplace-session", "cwd": fixture.root.path]
            ),
            fixture.line(
                timestamp: "2026-07-19T12:00:01.000Z",
                type: "turn_context",
                payload: ["turn_id": "marketplace-turn", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-curated-plugin", command: "cat \(curated.path)"),
            fixture.toolCall(callID: "call-bundled-plugin", command: "cat \(bundled.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-marketplaces.jsonl"))

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        let pluginSummaries = summaries.filter { $0.scope == "plugin" }

        XCTAssertEqual(pluginSummaries.count, 2)
        XCTAssertEqual(
            Set(pluginSummaries.map(\.id)),
            [
                "plugin:openai-curated/example-plugin:example-skill",
                "plugin:openai-bundled/example-plugin:example-skill",
            ]
        )
        XCTAssertTrue(pluginSummaries.allSatisfy { $0.totalInvocations == 1 })
    }

    func testSameSkillIdentityAtDifferentPathsProducesUniqueSummaryIDs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.makeSkill(
            at: "workspace/.agents/skills/first-folder",
            name: "shared-name"
        )
        let second = try fixture.makeSkill(
            at: "workspace/.agents/skills/second-folder",
            name: "shared-name"
        )
        try fixture.write([
            fixture.line(
                timestamp: "2026-07-19T12:00:00.000Z",
                type: "session_meta",
                payload: ["id": "path-collision-session", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "call-first-path", command: "cat \(first.path)"),
            fixture.toolCall(callID: "call-second-path", command: "cat \(second.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-path-collision.jsonl"))

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(Set(summaries.map(\.id)).count, 2)
        XCTAssertTrue(summaries.allSatisfy { $0.id.hasPrefix("path:") })
    }

    func testDefersAnIncompleteFinalRecordUntilItIsTerminated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/deferred", name: "deferred")
        let rollout = fixture.sessions.appendingPathComponent("rollout-partial.jsonl")
        let pendingLine = fixture.toolCall(callID: "call-pending", command: "cat \(skill.path)")
        let prefixCount = pendingLine.utf8.count - 12

        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "partial-session", "cwd": fixture.root.path]),
            fixture.line(type: "turn_context", payload: ["turn_id": "turn-1", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "call-complete", command: "cat \(skill.path)")
        ], to: rollout)
        try fixture.appendRaw(String(pendingLine.prefix(prefixCount)), to: rollout)

        let first = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(first.snapshot.totalInvocations, 1)
        XCTAssertFalse(first.snapshot.isBackfillComplete)

        let stalled = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(stalled.processedBytesAdvanced, 0)
        XCTAssertTrue(stalled.hasMore)

        try fixture.appendRaw(String(pendingLine.dropFirst(prefixCount)) + "\n", to: rollout)
        let second = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(second.invocationsAdded, 1)
        XCTAssertEqual(second.snapshot.totalInvocations, 2)
        XCTAssertTrue(second.snapshot.isBackfillComplete)
    }

    func testCountsOnlySupportedReadsAndHandlesQuotedPathsWithSpaces() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace with spaces/.agents/skills/skill with spaces",
            name: "space-skill"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-spaces.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "space-session", "cwd": fixture.root.path]),
            fixture.line(type: "turn_context", payload: ["turn_id": "turn-1", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "call-edit", command: "*** Update File: \(skill.path)", name: "apply_patch"),
            fixture.toolCall(callID: "call-reference", command: "echo \(skill.path)"),
            fixture.toolCall(callID: "call-quoted", command: "rg 'cat \(skill.path)' script.sh"),
            fixture.toolCall(
                callID: "call-heredoc",
                command: "cat <<'EOF' > script.sh\ncat \(skill.path)\nEOF"
            ),
            fixture.toolCall(
                callID: "call-write-target",
                command: "cat <<'EOF' > \(skill.path)\nreplacement\nEOF"
            ),
            fixture.toolCall(
                callID: "call-backup-file",
                command: "cat \(skill.path).bak",
                outputOverride: "backup content"
            ),
            fixture.toolCall(
                callID: "call-unknown-failure",
                command: "cat \(skill.path)",
                outputOverride: "cat: \(skill.path): No such file or directory"
            ),
            fixture.toolCall(
                callID: "call-conditional",
                command: "if false; then cat \(skill.path); fi"
            ),
            fixture.toolCall(
                callID: "call-failed",
                command: "cat \(skill.path)",
                succeeded: false
            ),
            fixture.toolCall(callID: "call-read", command: "sed -n '1,200p' '\(skill.path)'")
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        let summary = try XCTUnwrap(report.snapshot.summaries.first)
        XCTAssertEqual(summary.skillName, "space-skill")
        XCTAssertEqual(summary.scope, "project")
        XCTAssertEqual(summary.canonicalPath, skill.deletingLastPathComponent().path)
    }

    func testReindexesAFileThatShrinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/replaced", name: "replaced")
        let rollout = fixture.sessions.appendingPathComponent("rollout-replaced.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "old-session", "cwd": fixture.root.path]),
            fixture.line(type: "turn_context", payload: ["turn_id": "old-turn", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "old-call-1", command: "cat \(skill.path)"),
            fixture.toolCall(callID: "old-call-2", command: "cat \(skill.path)")
        ], to: rollout)
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.totalInvocations,
            2
        )

        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "new-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "new-call", command: "cat \(skill.path)")
        ], to: rollout)
        let replacement = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(replacement.invocationsAdded, 1)
        XCTAssertEqual(replacement.snapshot.totalInvocations, 1)
        XCTAssertEqual(replacement.snapshot.summaries.first?.distinctThreads, 1)
    }

    func testReindexesASameSizedReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldSkill = try fixture.makeSkill(at: "workspace/.agents/skills/oldskill", name: "oldskill")
        let newSkill = try fixture.makeSkill(at: "workspace/.agents/skills/newskill", name: "newskill")
        let rollout = fixture.sessions.appendingPathComponent("rollout-same-size.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "old-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "same-call", command: "cat \(oldSkill.path)")
        ], to: rollout)
        let oldSize = try XCTUnwrap(try rollout.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries.map(\.skillName),
            ["oldskill"]
        )

        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "new-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "same-call", command: "cat \(newSkill.path)")
        ], to: rollout)
        let newSize = try XCTUnwrap(try rollout.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(oldSize, newSize)

        let replacement = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(replacement.invocationsAdded, 1)
        XCTAssertEqual(replacement.snapshot.summaries.map(\.skillName), ["newskill"])
    }

    func testCarriesCursorWhenCodexMovesASessionToArchive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/archived", name: "archived")
        let rollout = fixture.sessions.appendingPathComponent("rollout-archive.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "archive-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "archive-read", command: "cat \(skill.path)")
        ], to: rollout)
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.totalInvocations,
            1
        )

        let archived = fixture.root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let archivedRollout = archived.appendingPathComponent(rollout.lastPathComponent)
        try FileManager.default.moveItem(at: rollout, to: archivedRollout)
        let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path, archived.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        ))
        XCTAssertEqual(report.bytesRead, 0)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertTrue(report.snapshot.isBackfillComplete)
    }

    func testCountsSuccessfulFunctionCallReads() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/function-read", name: "function-read")
        let rollout = fixture.sessions.appendingPathComponent("rollout-function.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "function-session", "cwd": fixture.root.path]),
            fixture.functionCall(callID: "function-read", command: "cat \(skill.path)")
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "function-read")
    }

    func testCountsSuccessfulLegacyShellCommandReads() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/legacy-shell",
            name: "legacy-shell"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-legacy-shell.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "legacy-shell-session",
                "cwd": fixture.root.path
            ]),
            fixture.legacyShellCall(callID: "legacy-shell-read", command: "cat \(skill.path)")
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "legacy-shell")
    }

    func testResolvesRelativeReadsAgainstWorkdirAndLeadingCD() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let workspace = fixture.root.appendingPathComponent("workspace")
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/relative", name: "relative")
        let relativePath = ".agents/skills/relative/SKILL.md"
        let rollout = fixture.sessions.appendingPathComponent("rollout-relative.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "relative-session", "cwd": fixture.root.path]),
            fixture.toolCall(
                callID: "workdir-read",
                command: "cat \(relativePath)",
                workdir: workspace.path
            ),
            fixture.toolCall(
                callID: "cd-read",
                command: "cd \(workspace.path) && cat \(relativePath)"
            )
        ], to: rollout)

        let summary = try XCTUnwrap(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries.first
        )
        XCTAssertEqual(summary.totalInvocations, 2)
        XCTAssertEqual(summary.canonicalPath, skill.deletingLastPathComponent().path)
    }

    func testMultipleWrapperReadsKeepPerCommandWorkdirsAndRepeats() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstWorkspace = fixture.root.appendingPathComponent("first-workspace")
        let secondWorkspace = fixture.root.appendingPathComponent("second-workspace")
        let firstSkill = try fixture.makeSkill(
            at: "first-workspace/.agents/skills/first-skill",
            name: "first-skill"
        )
        let secondSkill = try fixture.makeSkill(
            at: "second-workspace/.agents/skills/second-skill",
            name: "second-skill"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-multi-wrapper.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "multi-session",
                "cwd": secondWorkspace.path
            ]),
            fixture.multiToolCall(
                callID: "multi-read",
                commands: [
                    ("cat .agents/skills/first-skill/SKILL.md", firstWorkspace.path),
                    ("cat .agents/skills/second-skill/SKILL.md", nil),
                    ("cat .agents/skills/first-skill/SKILL.md", firstWorkspace.path)
                ],
                skillFiles: [firstSkill, secondSkill]
            )
        ], to: rollout)

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        XCTAssertEqual(summaries.first { $0.skillName == "first-skill" }?.totalInvocations, 2)
        XCTAssertEqual(summaries.first { $0.skillName == "first-skill" }?.repeatInvocations, 1)
        XCTAssertEqual(summaries.first { $0.skillName == "second-skill" }?.totalInvocations, 1)
    }

    func testRepeatedReadsInsideOneShellCommandRemainDistinct() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/same-command-repeat",
            name: "same-command-repeat"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-same-command-repeat.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "same-command-repeat-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(
                callID: "same-command-repeat",
                command: "cat \(skill.path); cat \(skill.path)"
            )
        ], to: rollout)

        let summary = try XCTUnwrap(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries.first
        )
        XCTAssertEqual(summary.totalInvocations, 2)
        XCTAssertEqual(summary.repeatInvocations, 1)
    }

    func testHistoricalOutputConfirmsASkillRemovedBeforeBackfill() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/removed-skill", name: "removed-skill")
        let rollout = fixture.sessions.appendingPathComponent("rollout-removed-skill.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "removed-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "removed-read", command: "cat \(skill.path)")
        ], to: rollout)
        try FileManager.default.removeItem(at: skill.deletingLastPathComponent())

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "removed-skill")
    }

    func testClassifiesIndependentCodexAndClaudeCopiesWithoutCollapsingThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let codexSkill = try fixture.makeSkill(
            at: "workspace/.codex/skills/independent",
            name: "independent"
        )
        let claudeSkill = try fixture.makeSkill(
            at: "workspace/.claude/skills/independent",
            name: "independent"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-containers.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "container-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "codex-read", command: "cat \(codexSkill.path)"),
            fixture.toolCall(callID: "claude-read", command: "cat \(claudeSkill.path)")
        ], to: rollout)

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        XCTAssertEqual(summaries.count, 2)
        XCTAssertTrue(summaries.allSatisfy { $0.scope == "project" })
        XCTAssertEqual(Set(summaries.map(\.id)).count, 2)
        XCTAssertTrue(summaries.contains { $0.id.contains(":codex:independent") })
        XCTAssertTrue(summaries.contains { $0.id.contains(":claude:independent") })
    }

    func testDefaultPathsHonorRedirectedHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("HOME", fixture.root.path, 1)
        unsetenv("CODEX_HOME")
        defer {
            restoreEnvironment("HOME", value: previousHome)
            restoreEnvironment("CODEX_HOME", value: previousCodexHome)
        }

        let skill = try fixture.makeSkill(at: ".agents/skills/global-skill", name: "global-skill")
        let defaultSessions = fixture.root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: defaultSessions, withIntermediateDirectories: true)
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "profile-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "profile-read", command: "cat ~/.agents/skills/global-skill/SKILL.md")
        ], to: defaultSessions.appendingPathComponent("rollout-profile.jsonl"))

        let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        ))
        XCTAssertEqual(report.snapshot.summaries.first?.scope, "global")
        XCTAssertEqual(report.snapshot.summaries.first?.canonicalPath, skill.deletingLastPathComponent().path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Library/Application Support/Metagent/usage.sqlite").path
        ))
    }

    func testRelocatedCodexHomeSkillsRemainGlobal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let relocatedCodexHome = fixture.root.appendingPathComponent("relocated-codex-home")
        setenv("CODEX_HOME", relocatedCodexHome.path, 1)
        defer { restoreEnvironment("CODEX_HOME", value: previousCodexHome) }

        let skill = try fixture.makeSkill(
            at: "relocated-codex-home/skills/relocated",
            name: "relocated"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-relocated.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "relocated-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "relocated-read", command: "cat \(skill.path)")
        ], to: rollout)

        let summary = try XCTUnwrap(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries.first
        )
        XCTAssertEqual(summary.id, "global:codex:relocated")
        XCTAssertEqual(summary.scope, "global")
    }

    func testKeepsSystemAndUserCodexSkillsDistinct() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", fixture.root.path, 1)
        defer { restoreEnvironment("HOME", value: previousHome) }
        let systemSkill = try fixture.makeSkill(at: ".codex/skills/.system/demo", name: "demo")
        let userSkill = try fixture.makeSkill(at: ".codex/skills/demo", name: "demo")
        let rollout = fixture.sessions.appendingPathComponent("rollout-system.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "system-session", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "system-read", command: "cat \(systemSkill.path)"),
            fixture.toolCall(callID: "user-read", command: "cat \(userSkill.path)")
        ], to: rollout)

        let summaries = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.summaries
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(Set(summaries.map(\.scope)), Set(["system", "global"]))
        XCTAssertEqual(Set(summaries.map(\.id)).count, 2)
    }

    func testThrottleCarriesAcrossSmallFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/throttled", name: "throttled")
        let first = fixture.sessions.appendingPathComponent("rollout-throttle-1.jsonl")
        let second = fixture.sessions.appendingPathComponent("rollout-throttle-2.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "throttle-1", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "read-1", command: "cat \(skill.path)")
        ], to: first)
        try fixture.write([
            fixture.line(type: "session_meta", payload: ["id": "throttle-2", "cwd": fixture.root.path]),
            fixture.toolCall(callID: "read-2", command: "cat \(skill.path)")
        ], to: second)
        let firstSize = try XCTUnwrap(
            try first.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let secondSize = try XCTUnwrap(
            try second.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let interval = Int64(max(firstSize, secondSize) + 1)
        let startedAt = Date()
        let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20,
            throttleEveryBytes: interval,
            throttleDelayMilliseconds: 60
        ))

        XCTAssertEqual(report.snapshot.totalInvocations, 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.05)
    }

    func testSkipsARecordLargerThanTheByteLimitAndResumes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(at: "workspace/.agents/skills/oversized", name: "oversized")
        let rollout = fixture.sessions.appendingPathComponent("rollout-oversized.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "oversized-session",
                "cwd": fixture.root.path,
                "padding": String(repeating: "x", count: 8_000)
            ]),
            fixture.toolCall(callID: "oversized-read", command: "cat \(skill.path)")
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024,
            maxFiles: 20
        ))
        XCTAssertGreaterThan(report.bytesRead, 1_024)
        XCTAssertGreaterThan(report.processedBytesAdvanced, 1_024)
        XCTAssertEqual(report.snapshot.totalInvocations, 0)
        XCTAssertTrue(report.hasMore)
        XCTAssertEqual(report.warnings.count, 1)

        let resumed = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        ))
        XCTAssertEqual(resumed.snapshot.totalInvocations, 1)
        XCTAssertTrue(resumed.snapshot.isBackfillComplete)
    }

    func testSuccessfulPartialReadWithoutFrontmatterIsObserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/partial-read",
            name: "partial-read"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-partial-read.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "partial-read-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(
                callID: "partial-read",
                command: "tail -n 1 \(skill.path)",
                outputOverride: "final instruction line"
            )
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "partial-read")
    }

    func testSkillContentDoesNotOverrideSuccessfulProcessStatus() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/failure-examples",
            name: "failure-examples"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-failure-examples.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "failure-examples-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(
                callID: "failure-examples-read",
                command: "cat \(skill.path)",
                outputOverride: "---\nname: failure-examples\n---\nScript failed\nProcess exited with code 1\n\"exit_code\": 1"
            )
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 1)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "failure-examples")
    }

    func testNestedCommandFailureOverridesCompletedWrapper() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/nested-failure",
            name: "nested-failure"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-nested-failure.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "nested-failure-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(
                callID: "nested-failure-read",
                command: "cat \(skill.path)",
                outputOverride: "{\"exit_code\":1,\"output\":\"cat failed\"}"
            )
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 0)
    }

    func testCompoundCommandUsesPerReadEvidenceInsteadOfAggregateExit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let valid = try fixture.makeSkill(
            at: "workspace/.agents/skills/compound-valid",
            name: "compound-valid"
        )
        let missing = fixture.root.appendingPathComponent(
            "workspace/.agents/skills/compound-missing/SKILL.md"
        )
        let rollout = fixture.sessions.appendingPathComponent("rollout-compound-status.jsonl")
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "compound-status-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(
                callID: "aggregate-success",
                command: "cat \(missing.path); true",
                outputOverride: "cat: \(missing.path): No such file or directory"
            ),
            fixture.toolCall(
                callID: "aggregate-failure",
                command: "cat \(valid.path); false",
                succeeded: false,
                outputOverride: try String(contentsOf: valid, encoding: .utf8)
            ),
            fixture.toolCall(
                callID: "mixed-evidence",
                command: "cat \(valid.path); cat \(missing.path); true",
                outputOverride: try String(contentsOf: valid, encoding: .utf8)
                    + "\ncat: \(missing.path): No such file or directory"
            )
        ], to: rollout)

        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalInvocations, 2)
        XCTAssertEqual(report.snapshot.summaries.first?.skillName, "compound-valid")
    }

    func testCoverageStartsAtEarliestProcessedSession() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/coverage",
            name: "coverage"
        )
        try fixture.write([
            fixture.line(
                timestamp: "2025-01-02T03:04:05.000Z",
                type: "session_meta",
                payload: ["id": "early-session", "cwd": fixture.root.path]
            )
        ], to: fixture.sessions.appendingPathComponent("rollout-early.jsonl"))
        try fixture.write([
            fixture.line(
                timestamp: "2026-01-02T03:04:05.000Z",
                type: "session_meta",
                payload: ["id": "later-session", "cwd": fixture.root.path]
            ),
            fixture.toolCall(callID: "coverage-read", command: "cat \(skill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-later.jsonl"))

        let snapshot = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot
        XCTAssertEqual(snapshot.coverageStartedAt, "2025-01-02T03:04:05.000Z")
        XCTAssertEqual(snapshot.totalInvocations, 1)
    }

    func testEmptyHistoryRemainsInsufficient() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertEqual(report.snapshot.totalFiles, 0)
        XCTAssertFalse(report.snapshot.isBackfillComplete)
        XCTAssertFalse(report.hasMore)
    }

    func testSnapshotKeepsResultsFromAnOlderParserVersionVisible() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/stale-parser",
            name: "stale-parser"
        )
        try fixture.write([
            fixture.line(type: "session_meta", payload: [
                "id": "stale-parser-session",
                "cwd": fixture.root.path
            ]),
            fixture.toolCall(callID: "stale-parser-read", command: "cat \(skill.path)")
        ], to: fixture.sessions.appendingPathComponent("rollout-stale-parser.jsonl"))
        XCTAssertEqual(
            try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot.totalInvocations,
            1
        )

        try fixture.executeSQL(
            "UPDATE skill_usage_metadata SET value = '13' WHERE key = 'parser_version';"
        )
        let snapshot = try XCTUnwrap(
            MetagentCore.loadSkillUsageSnapshot(databasePath: fixture.database.path)
        )
        XCTAssertEqual(snapshot.totalInvocations, 1)
        XCTAssertFalse(snapshot.isBackfillComplete)
        XCTAssertTrue(snapshot.isParserUpgradeBackfill)
        XCTAssertEqual(snapshot.displayParserVersion, 13)
        XCTAssertEqual(snapshot.targetParserVersion, 15)
    }

    func testParserUpgradeServesPreviousGenerationUntilAtomicCutover() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.makeSkill(
            at: "workspace/.agents/skills/generation-skill",
            name: "generation-skill"
        )
        for index in 1...2 {
            try fixture.write([
                fixture.line(type: "session_meta", payload: [
                    "id": "generation-session-\(index)",
                    "cwd": fixture.root.path
                ]),
                fixture.toolCall(
                    callID: "generation-read-\(index)",
                    command: "cat \(skill.path)"
                )
            ], to: fixture.sessions.appendingPathComponent("rollout-generation-\(index).jsonl"))
        }

        let original = try MetagentCore.refreshSkillUsage(options: fixture.options).snapshot
        XCTAssertEqual(original.totalInvocations, 2)
        XCTAssertTrue(original.isBackfillComplete)

        try fixture.executeSQL(
            "UPDATE skill_usage_metadata SET value = '13' WHERE key = 'parser_version';"
        )
        let rebuilding = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 1
        ))
        XCTAssertTrue(rebuilding.hasMore)
        XCTAssertEqual(rebuilding.snapshot.totalInvocations, 2)
        XCTAssertEqual(rebuilding.snapshot.completedFiles, 1)
        XCTAssertTrue(rebuilding.snapshot.isParserUpgradeBackfill)
        XCTAssertEqual(rebuilding.snapshot.displayParserVersion, 13)

        try fixture.executeSQL(
            "UPDATE skill_usage_metadata SET value = '12' WHERE key = 'parser_version';"
        )
        let restartedUpgrade = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: fixture.database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 1
        ))
        XCTAssertTrue(restartedUpgrade.hasMore)
        XCTAssertEqual(restartedUpgrade.invocationsAdded, 1)
        XCTAssertEqual(restartedUpgrade.snapshot.totalInvocations, 2)
        XCTAssertEqual(restartedUpgrade.snapshot.completedFiles, 1)
        XCTAssertTrue(restartedUpgrade.snapshot.isParserUpgradeBackfill)
        XCTAssertEqual(restartedUpgrade.snapshot.displayParserVersion, 13)

        let cutover = try MetagentCore.refreshSkillUsage(options: fixture.options)
        XCTAssertFalse(cutover.hasMore)
        XCTAssertEqual(cutover.snapshot.totalInvocations, 2)
        XCTAssertTrue(cutover.snapshot.isBackfillComplete)
        XCTAssertFalse(cutover.snapshot.isParserUpgradeBackfill)
        XCTAssertEqual(cutover.snapshot.displayParserVersion, 15)
    }
}

private func restoreEnvironment(_ name: String, value: String?) {
    if let value {
        setenv(name, value, 1)
    } else {
        unsetenv(name)
    }
}

private final class Fixture {
    let root: URL
    let sessions: URL
    let database: URL

    var options: SkillUsageRefreshOptions {
        SkillUsageRefreshOptions(
            sessionRoots: [sessions.path],
            databasePath: database.path,
            maxBytes: 1_024 * 1_024,
            maxFiles: 20
        )
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-usage-tests-\(UUID().uuidString)")
        sessions = root.appendingPathComponent("sessions")
        database = root.appendingPathComponent("usage.sqlite")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    func makeSkill(at relativePath: String, name: String) throws -> URL {
        let directory = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("SKILL.md")
        try "---\nname: \(name)\ndescription: fixture\n---\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func line(
        timestamp: String = "2026-07-19T12:00:00.000Z",
        type: String,
        payload: [String: Any]
    ) -> String {
        json(["timestamp": timestamp, "type": type, "payload": payload])
    }

    func toolCall(
        callID: String,
        command: String,
        name: String = "exec",
        succeeded: Bool = true,
        workdir: String? = nil,
        outputOverride: String? = nil
    ) -> String {
        let commandData = try! JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed])
        let commandLiteral = String(decoding: commandData, as: UTF8.self)
        let workdirFragment: String
        if let workdir {
            let data = try! JSONSerialization.data(withJSONObject: workdir, options: [.fragmentsAllowed])
            workdirFragment = ", workdir: \(String(decoding: data, as: UTF8.self))"
        } else {
            workdirFragment = ""
        }
        let request = line(type: "response_item", payload: [
            "type": "custom_tool_call",
            "name": name,
            "call_id": callID,
            "input": "const result = await tools.exec_command({cmd: \(commandLiteral)\(workdirFragment)});"
        ])
        let wrapper = succeeded
            ? "Script completed\nWall time 0.1 seconds\nOutput:\n"
            : "Process exited with code 1"
        let actualOutput = succeeded
            ? (outputOverride ?? skillOutput(for: command, workdir: workdir))
            : (outputOverride ?? "cat: No such file or directory")
        let output = line(type: "response_item", payload: [
            "type": "custom_tool_call_output",
            "call_id": callID,
            "output": [
                ["type": "input_text", "text": wrapper],
                ["type": "input_text", "text": actualOutput]
            ]
        ])
        return request + "\n" + output
    }

    private func skillOutput(for command: String, workdir: String?) -> String {
        let patterns = [
            #"['\"]((?:~|/|\.\.?/)?[^'\"\n]*?/SKILL\.md)['\"]"#,
            #"((?:~|/|\.\.?/)?[^\s'\";&|]*?/SKILL\.md)"#
        ]
        let path = patterns.lazy.compactMap { pattern -> String? in
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: command,
                    range: NSRange(command.startIndex..<command.endIndex, in: command)
                  ),
                  let pathRange = Range(match.range(at: 1), in: command)
            else { return nil }
            return String(command[pathRange])
        }.first
        guard var path else { return "" }
        if path.hasPrefix("~/") {
            path = root.appendingPathComponent(String(path.dropFirst(2))).path
        } else if !path.hasPrefix("/") {
            let base: URL
            if let workdir {
                base = URL(fileURLWithPath: workdir)
            } else if let cdRange = command.range(
                of: #"^\s*cd\s+([^;&|\s]+)\s*&&"#,
                options: .regularExpression
            ) {
                let cdCommand = String(command[cdRange])
                let directory = cdCommand
                    .replacingOccurrences(of: #"^\s*cd\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*&&$"#, with: "", options: .regularExpression)
                base = URL(fileURLWithPath: directory)
            } else {
                base = root
            }
            path = base.appendingPathComponent(path).path
        }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    func functionCall(callID: String, command: String) -> String {
        let argumentsData = try! JSONSerialization.data(withJSONObject: ["cmd": command])
        let arguments = String(decoding: argumentsData, as: UTF8.self)
        let request = line(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "call_id": callID,
            "arguments": arguments
        ])
        let resultData = try! JSONSerialization.data(withJSONObject: [
            "exit_code": 0,
            "output": skillOutput(for: command, workdir: nil)
        ])
        let output = line(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": callID,
            "output": String(decoding: resultData, as: UTF8.self)
        ])
        return request + "\n" + output
    }

    func legacyShellCall(callID: String, command: String) -> String {
        let argumentsData = try! JSONSerialization.data(withJSONObject: [
            "command": command,
            "workdir": root.path
        ])
        let arguments = String(decoding: argumentsData, as: UTF8.self)
        let request = line(type: "response_item", payload: [
            "type": "function_call",
            "name": "shell_command",
            "call_id": callID,
            "arguments": arguments
        ])
        let resultData = try! JSONSerialization.data(withJSONObject: [
            "exit_code": 0,
            "output": skillOutput(for: command, workdir: root.path)
        ])
        let output = line(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": callID,
            "output": String(decoding: resultData, as: UTF8.self)
        ])
        return request + "\n" + output
    }

    func multiToolCall(
        callID: String,
        commands: [(command: String, workdir: String?)],
        skillFiles: [URL]
    ) -> String {
        let calls = commands.map { item -> String in
            let commandData = try! JSONSerialization.data(
                withJSONObject: item.command,
                options: [.fragmentsAllowed]
            )
            let command = String(decoding: commandData, as: UTF8.self)
            guard let workdir = item.workdir else {
                return "tools.exec_command({cmd: \(command)})"
            }
            let workdirData = try! JSONSerialization.data(
                withJSONObject: workdir,
                options: [.fragmentsAllowed]
            )
            return "tools.exec_command({cmd: \(command), workdir: \(String(decoding: workdirData, as: UTF8.self))})"
        }
        let request = line(type: "response_item", payload: [
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": callID,
            "input": "const results = await Promise.all([\(calls.joined(separator: ", "))]);"
        ])
        let observed = skillFiles.compactMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")
        let output = line(type: "response_item", payload: [
            "type": "custom_tool_call_output",
            "call_id": callID,
            "output": [["type": "input_text", "text": "Script completed\n\(observed)"]]
        ])
        return request + "\n" + output
    }

    func write(_ lines: [String], to file: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    func append(_ lines: [String], to file: URL) throws {
        try appendRaw(lines.joined(separator: "\n") + "\n", to: file)
    }

    func appendRaw(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func executeSQL(_ sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else {
            throw NSError(domain: "SkillUsageTests", code: 1)
        }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SkillUsageTests", code: 2)
        }
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
