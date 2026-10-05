import Foundation
import XCTest
@testable import MetagentCore

final class SkillDetailInventoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    func testDetailReadsOnlySelectedBundleButPreservesWholeSerializedOutput() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-bounded-detail")
        let selected = try bundle(root.appendingPathComponent(".agents/skills/demo"))
        for index in 0..<24 {
            try bundle(root.appendingPathComponent(".agents/skills/unrelated-\(index)"))
        }
        for location in ["codex", "claude"] {
            try link(root.appendingPathComponent(".\(location)/skills/demo"), to: selected)
        }
        try bundle(root.appendingPathComponent(".codex/skills/nested/demo"), description: "Independent same-name source")
        var reads: [String] = []
        for path in [selected.path, root.appendingPathComponent(".claude/skills/demo/SKILL.md").path] {
            let detail = try bounded(path: path, root: root, readStats: {
                reads.append($0.path)
                return skillStats($0)
            })
            let expected = try full(path: path, root: root)
            XCTAssertEqual(detail, expected)
            XCTAssertEqual(try encoded(detail), try encoded(expected))
            XCTAssertEqual(detail.size?.scriptFileCount, 1)
            XCTAssertEqual(detail.scriptInventory.scripts.first?.referencedBy, ["SKILL.md", "references/guide.md"])
            XCTAssertEqual(detail.body?.count, 13)
            XCTAssertTrue(detail.bodyTruncated)
        }
        XCTAssertEqual(reads, [canonicalProjectPath(selected), canonicalProjectPath(selected)])
    }

    func testCanonicalAliasOrderingRetainsTheMatchedNameVariantsNotTheRequestedName() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-alias-detail")
        let selected = try bundle(root.appendingPathComponent(".agents/skills/demo"))
        try link(root.appendingPathComponent(".agents/skills/aaa"), to: selected)
        try link(root.appendingPathComponent(".codex/skills/nested/renamed"), to: selected)
        try bundle(root.appendingPathComponent(".claude/skills/aaa"), description: "Independent alias identity")
        let detail = try bounded(path: root.appendingPathComponent(".codex/skills/nested/renamed").path, root: root)
        let expected = try full(path: root.appendingPathComponent(".codex/skills/nested/renamed").path, root: root)
        XCTAssertEqual(detail, expected)
        XCTAssertEqual(detail.name, "document-name")
        XCTAssertEqual(detail.locationLabel, ".agents")
        XCTAssertEqual(detail.provenance?.representation, "projection")

        // The first sorted canonical match is the agents alias "aaa". Its
        // independent same-name source must still reduce clarity by 14 points.
        let report = try ordinaryScan(root)
        let match = try XCTUnwrap(report.projects.first?.skills.first)
        XCTAssertEqual(match.name, "aaa")
        let expectedScore = MetagentCore.scoreSkill(
            match, variants: report.projects.flatMap(\.skills).filter { $0.name == "aaa" },
            usage: nil, usageCoverageComplete: false, now: now
        )
        XCTAssertEqual(detail.score, expectedScore.score)
    }

    func testDetailPreservesLocksDotagentsAndExternalCLIManagerEvidence() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-managed-detail")
        let locked = try bundle(root.appendingPathComponent(".agents/skills/locked"))
        let adopted = try bundle(root.appendingPathComponent(".agents/skills/adopted"))
        let managed = try bundle(root.appendingPathComponent(".agents/skills/managed"))
        try write("""
        {"skills":{"locked":{"source":"example/package","sourceType":"github","ref":"v1","updatedAt":"2026-07-20T12:00:00.000Z"}}}
        """, to: root.appendingPathComponent("skills-lock.json"))
        try write("""
        version = 1
        [[skills]]
        name = "adopted"
        source = "path:.agents/skills/adopted"
        [[skills]]
        name = "managed"
        source = "https://example.invalid/skills"
        """, to: root.appendingPathComponent("agents.toml"))
        let external = try bundle(root.appendingPathComponent(".agents/skills/impeccable"))
        try write("---\nname: impeccable\ndescription: external\nversion: 3.9.1\n---\nRun .agents/skills/impeccable/scripts/context.mjs.\n", to: external.appendingPathComponent("SKILL.md"))
        try write("// synthetic\n", to: external.appendingPathComponent("scripts/context.mjs"))
        try write("hooks\n", to: external.appendingPathComponent("reference/hooks.md"))
        let managers = [(locked, "skills-cli"), (adopted, "local"), (managed, "dotagents"), (external, "external-cli")]
        for (path, manager) in managers {
            try link(root.appendingPathComponent(".claude/skills/\(path.lastPathComponent)"), to: path)
            let detail = try bounded(path: path.path, root: root)
            XCTAssertEqual(detail, try full(path: path.path, root: root))
            XCTAssertEqual(detail.provenance?.manager, manager)
        }
    }

    func testLaterDetailsRereadSameSizeEditsAndRetargetedProjection() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-fresh-detail")
        let selected = try bundle(root.appendingPathComponent(".agents/skills/demo"), description: "first")
        let other = try bundle(root.appendingPathComponent(".codex/skills/demo"), description: "other")
        let projection = root.appendingPathComponent(".claude/skills/demo")
        try link(projection, to: selected)
        let script = selected.appendingPathComponent("scripts/demo.py")
        let document = selected.appendingPathComponent("SKILL.md")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for path in [script, document] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        }
        let first = try bounded(path: projection.path, root: root)
        for (path, before, after) in [(document, "first", "newer"), (script, "one", "two")] {
            let text = try String(contentsOf: path, encoding: .utf8)
            let replacement = text.replacingOccurrences(of: before, with: after)
            XCTAssertEqual(text.utf8.count, replacement.utf8.count)
            try replacement.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        }
        let second = try bounded(path: projection.path, root: root)
        XCTAssertEqual(second, try full(path: projection.path, root: root))
        XCTAssertEqual(second.description, "newer")
        XCTAssertNotEqual(first.scriptInventory.scripts.first?.sha256, second.scriptInventory.scripts.first?.sha256)
        try FileManager.default.removeItem(at: projection)
        try link(projection, to: other)
        let retargeted = try bounded(path: projection.path, root: root)
        XCTAssertEqual(retargeted, try full(path: projection.path, root: root))
        XCTAssertEqual(retargeted.description, "other")
        XCTAssertEqual(retargeted.locationLabel, ".claude")
    }

    func testOutOfInventoryAndFailedInventoryKeepTheExistingDegradedDetail() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-degraded-detail")
        let tooDeep = try bundle(root.appendingPathComponent(".codex/skills/a/b/c/demo"))
        let invalid = try bundle(root.appendingPathComponent(".agents/skills/.hidden"))
        let detached = try bundle(root.appendingPathComponent("standalone/demo"))
        for path in [tooDeep, invalid, detached] {
            var reads = 0
            let detail = try bounded(path: path.path, root: root, readStats: {
                reads += 1
                return skillStats($0)
            })
            XCTAssertEqual(detail, try full(path: path.path, root: root))
            XCTAssertNil(detail.provenance)
            XCTAssertNil(detail.size)
            XCTAssertEqual(detail.scriptInventory.scripts.count, 1)
            XCTAssertEqual(reads, 0)
        }
        let selected = try bundle(root.appendingPathComponent(".agents/skills/demo"))
        let failed = try MetagentCore.getSkillDetail(
            path: selected.path, readInventory: { _, _ in throw MetagentCore.skillQueryError("synthetic failure") },
            loadUsage: { .empty }
        )
        XCTAssertNil(failed.projectRoot)
        XCTAssertNil(failed.provenance)
        XCTAssertNil(failed.size)
        XCTAssertEqual(failed.scriptInventory.scripts.count, 1)
    }

    func testDocumentErrorsPrecedeInventoryAndUsageReads() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-invalid-detail")
        var dependencies = 0
        XCTAssertThrowsError(try MetagentCore.getSkillDetail(
            path: root.path,
            readInventory: { _, _ in dependencies += 1; return SkillScanReport(projects: []) },
            loadUsage: { dependencies += 1; return .empty }
        ))
        XCTAssertEqual(dependencies, 0)
    }

    func testProjectionOnlySymlinkedContainerRetainsSystemAndStandaloneOwnership() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-projection-only-detail")
        let outside = root.appendingPathComponent("external")
        let selected = try bundle(outside.appendingPathComponent("demo"))
        try link(root.appendingPathComponent(".claude/skills"), to: outside)
        try link(root.appendingPathComponent(".codex/skills/.system/demo"), to: selected)
        for path in [root.appendingPathComponent(".claude/skills/demo"), root.appendingPathComponent(".codex/skills/.system/demo")] {
            var reads: [String] = []
            let detail = try bounded(path: path.path, root: root, readStats: {
                reads.append($0.path)
                return skillStats($0)
            })
            XCTAssertEqual(detail, try full(path: path.path, root: root))
            XCTAssertEqual(reads, [canonicalProjectPath(selected)])
            XCTAssertEqual(detail.provenance?.representation, "projection")
            XCTAssertEqual(detail.provenance?.mutability, "managed-read-only")
        }
    }

    func testBodyOmissionAndNegativeLimitAreUnchangedWithUnicode() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-detail-body-modes")
        let selected = try bundle(root.appendingPathComponent(".agents/skills/demo"))
        for includeBody in [true, false] {
            let candidate = try MetagentCore.getSkillDetail(
                path: selected.path, includeBody: includeBody, maxBodyCharacters: -1, now: now,
                readInventory: { inferred, directory in
                    try MetagentCore.skillDetailInventory(root: inferred, directory: directory, config: MetagentConfig(roots: [root.path]))
                }, loadUsage: { .empty }
            )
            let expected = try MetagentCore.getSkillDetail(
                path: selected.path, includeBody: includeBody, maxBodyCharacters: -1, now: now,
                readInventory: { inferred, _ in try self.ordinaryScan(inferred) }, loadUsage: { .empty }
            )
            XCTAssertEqual(candidate, expected)
            XCTAssertEqual(candidate.body, includeBody ? "" : nil)
            XCTAssertEqual(candidate.bodyTruncated, includeBody)
        }
    }

    func testSelectedDetailRetainsUsageCanonicalJoinAndIdentityFallback() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-detail-usage")
        let selected = try bundle(root.appendingPathComponent(".agents/skills/demo"))
        for path in [selected.path, "/synthetic/missing/demo"] {
            let summary = SkillUsageSummary(
                id: "project:\(path):demo", skillName: "demo", canonicalPath: path, scope: "project",
                totalInvocations: 3, invocations7d: 2, invocations30d: 3, activeTurns: 3,
                distinctThreads: 2, repeatInvocations: 1, directInvocations: 3, inferredInvocations: 0,
                firstUsedAt: "2026-01-01T00:00:00Z", lastUsedAt: "2026-05-01T00:00:00Z"
            )
            let usage = SkillUsageSnapshot(
                summaries: [summary], totalInvocations: 3, totalFiles: 1, completedFiles: 1,
                totalBytes: 1, processedBytes: 1, isBackfillComplete: true,
                isParserUpgradeBackfill: false, displayParserVersion: 1, targetParserVersion: 1,
                coverageStartedAt: "2026-01-01T00:00:00Z", lastUpdatedAt: "2026-05-01T00:00:00Z"
            )
            var usageLoads = 0
            let candidate = try MetagentCore.getSkillDetail(
                path: selected.path, now: now,
                readInventory: { inferred, directory in
                    try MetagentCore.skillDetailInventory(root: inferred, directory: directory, config: MetagentConfig(roots: [root.path]))
                }, loadUsage: { usageLoads += 1; return usage }
            )
            let expected = try MetagentCore.getSkillDetail(
                path: selected.path, now: now,
                readInventory: { inferred, _ in try self.ordinaryScan(inferred) }, loadUsage: { usage }
            )
            XCTAssertEqual(candidate, expected)
            XCTAssertEqual(candidate.usage?.totalInvocations, 3)
            XCTAssertEqual(usageLoads, 1)
        }
    }

    private func bounded(
        path: String,
        root: URL,
        readStats: @escaping (URL) -> SkillStats = skillStats
    ) throws -> SkillDetail {
        try MetagentCore.getSkillDetail(
            path: path, maxBodyCharacters: 13, now: now,
            readInventory: { inferred, directory in
                try MetagentCore.skillDetailInventory(
                    root: inferred, directory: directory,
                    config: MetagentConfig(roots: [root.path]), readStats: readStats
                )
            },
            loadUsage: { .empty }
        )
    }

    private func full(path: String, root: URL) throws -> SkillDetail {
        try MetagentCore.getSkillDetail(
            path: path, maxBodyCharacters: 13, now: now,
            readInventory: { inferred, _ in try self.ordinaryScan(inferred) },
            loadUsage: { .empty }
        )
    }

    private func ordinaryScan(_ root: URL) throws -> SkillScanReport {
        try MetagentCore.scanSkills(
            options: SkillScanOptions(roots: [root.path], maxDepth: 0, respectConfiguredIgnores: false),
            config: MetagentConfig(roots: [root.path])
        )
    }

    @discardableResult
    private func bundle(_ path: URL, description: String = "Selected Unicode café 東京") throws -> URL {
        try writeSkillFixture(
            at: path, name: "document-name", description: description,
            body: "Unicode 👩🏽‍💻 e\u{301} 🇺🇸. Run scripts/demo.py.\n"
        )
        try write("#!/usr/bin/env python3\nprint('one')\n", to: path.appendingPathComponent("scripts/demo.py"))
        try write("Reference scripts/demo.py.\n", to: path.appendingPathComponent("references/guide.md"))
        return path
    }

    private func write(_ text: String, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    private func link(_ path: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
    }

    private func encoded(_ detail: SkillDetail) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(detail)
    }
}
