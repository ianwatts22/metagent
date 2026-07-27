import Foundation
import XCTest
@testable import MetagentCore

/// A real `.claude/skills` directory can hold the only copy of a skill, so these
/// cover what happens to those files rather than just whether the link appears.
final class ClaudeSkillsMigrationTests: XCTestCase {
    func testMovesClaudeOnlySkillsIntoAgentsThenLinks() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-migration")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/shared"), name: "shared")
        try writeSkillFixture(
            at: root.appendingPathComponent(".claude/skills/handwritten"),
            name: "handwritten",
            body: "only copy"
        )

        let lines = try repair(root, apply: true)

        let migrated = root.appendingPathComponent(".agents/skills/handwritten/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.path))
        XCTAssertTrue(try String(contentsOf: migrated, encoding: .utf8).contains("only copy"))
        XCTAssertTrue(isSymlink(root.appendingPathComponent(".claude/skills")))
        XCTAssertTrue(symlink(
            root.appendingPathComponent(".claude/skills"),
            resolvesTo: root.appendingPathComponent(".agents/skills")
        ))
        XCTAssertTrue(lines.contains { $0.kind == .action && $0.text.contains("moved 1 skill(s)") })
    }

    func testPreviewMovesNothing() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-migration")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/shared"), name: "shared")
        try writeSkillFixture(at: root.appendingPathComponent(".claude/skills/handwritten"), name: "handwritten")

        let lines = try repair(root, apply: false)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".claude/skills/handwritten/SKILL.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".agents/skills/handwritten").path
        ))
        XCTAssertTrue(lines.contains { $0.kind == .action && $0.text.contains("would move 1 skill(s)") })
    }

    func testRefusesWhenTheSameSkillNameExistsInBothPlaces() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-migration")
        try writeSkillFixture(
            at: root.appendingPathComponent(".agents/skills/demo"),
            name: "demo",
            body: "canonical copy"
        )
        try writeSkillFixture(
            at: root.appendingPathComponent(".claude/skills/demo"),
            name: "demo",
            body: "divergent copy"
        )

        let lines = try repair(root, apply: true)

        // Both copies survive untouched and no link is created.
        let claudeCopy = root.appendingPathComponent(".claude/skills/demo/SKILL.md")
        let agentsCopy = root.appendingPathComponent(".agents/skills/demo/SKILL.md")
        XCTAssertTrue(try String(contentsOf: claudeCopy, encoding: .utf8).contains("divergent copy"))
        XCTAssertTrue(try String(contentsOf: agentsCopy, encoding: .utf8).contains("canonical copy"))
        XCTAssertFalse(isSymlink(root.appendingPathComponent(".claude/skills")))
        XCTAssertTrue(lines.contains { $0.kind == .skipped && $0.text.contains("exist in both") })
    }

    func testDropsLinksThatAlreadyPointIntoTheCanonicalCollection() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-migration")
        let canonical = root.appendingPathComponent(".agents/skills/demo")
        try writeSkillFixture(at: canonical, name: "demo")
        let claudeSkills = root.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: claudeSkills.appendingPathComponent("demo"),
            withDestinationURL: canonical
        )

        _ = try repair(root, apply: true)

        // The per-skill link is redundant once the folder itself is the link,
        // and the canonical skill must survive being pointed at.
        XCTAssertTrue(isSymlink(claudeSkills))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.appendingPathComponent("SKILL.md").path))
    }

    func testDoctorOffersRepairOnlyWhenMigrationIsPossible() throws {
        let migratable = try makeTemporaryRoot(prefix: "metagent-claude-migration")
        try writeSkillFixture(at: migratable.appendingPathComponent(".agents/skills/shared"), name: "shared")
        try writeSkillFixture(at: migratable.appendingPathComponent(".claude/skills/extra"), name: "extra")

        let blocked = try makeTemporaryRoot(prefix: "metagent-claude-migration")
        try writeSkillFixture(at: blocked.appendingPathComponent(".agents/skills/demo"), name: "demo")
        try writeSkillFixture(at: blocked.appendingPathComponent(".claude/skills/demo"), name: "demo")

        let migratableIssue = try XCTUnwrap(doctorProjectionIssue(migratable))
        XCTAssertEqual(migratableIssue.repairAction, .repairProjection)

        let blockedIssue = try XCTUnwrap(doctorProjectionIssue(blocked))
        XCTAssertNil(blockedIssue.repairAction)
        XCTAssertEqual(blockedIssue.severity, .warning)
    }

    // MARK: - Helpers

    private func repair(_ root: URL, apply: Bool) throws -> [SkillsRepairLine] {
        let report = try MetagentCore.repairSkills(options: SkillsRepairOptions(
            apply: apply,
            scanOptions: SkillScanOptions(roots: [root.path], maxDepth: 0, respectConfiguredIgnores: false)
        ))
        return report.projects.flatMap(\.lines)
    }

    private func doctorProjectionIssue(_ root: URL) throws -> DoctorIssue? {
        try MetagentCore.doctor(options: SkillScanOptions(
            roots: [root.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        ))
        .issues
        .first { $0.category == .projection && $0.severity != .ok }
    }
}
