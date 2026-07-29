import Foundation
import XCTest
@testable import MetagentCore

/// Skills CLI owns names in `skills-lock.json`. Metagent projects only the
/// remaining project-local names, one child link at a time.
final class ClaudeSkillsMigrationTests: XCTestCase {
    func testLinksOnlyPersonalSkillsAndLeavesSkillsCLINamesAlone() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-projection")
        let personal = root.appendingPathComponent(".agents/skills/personal")
        let managed = root.appendingPathComponent(".agents/skills/managed")
        try writeSkillFixture(at: personal, name: "personal")
        try writeSkillFixture(at: managed, name: "managed")
        try writeSkillsLock(root, names: ["managed"])

        let lines = try repair(root, apply: true)

        let personalLink = root.appendingPathComponent(".claude/skills/personal")
        XCTAssertTrue(isSymlink(personalLink))
        XCTAssertTrue(symlink(personalLink, resolvesTo: personal))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".claude/skills/managed").path
        ))
        XCTAssertFalse(isSymlink(root.appendingPathComponent(".claude/skills")))
        XCTAssertTrue(lines.contains {
            $0.kind == .action && $0.text == "linked personal Claude skill: personal"
        })
    }

    func testPreviewCreatesNoDirectoriesOrLinks() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-projection")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/personal"), name: "personal")

        let lines = try repair(root, apply: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude").path))
        XCTAssertTrue(lines.contains {
            $0.kind == .action && $0.text == "would link personal Claude skill: personal"
        })
    }

    func testPreservesRealClaudeSpecificOverride() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-projection")
        try writeSkillFixture(
            at: root.appendingPathComponent(".agents/skills/impeccable"),
            name: "impeccable",
            body: "generic copy"
        )
        let claudeOverride = root.appendingPathComponent(".claude/skills/impeccable")
        try writeSkillFixture(at: claudeOverride, name: "impeccable", body: "Claude copy")

        let lines = try repair(root, apply: true)

        XCTAssertFalse(isSymlink(claudeOverride))
        XCTAssertTrue(try String(
            contentsOf: claudeOverride.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ).contains("Claude copy"))
        XCTAssertTrue(lines.contains {
            $0.kind == .info && $0.text.contains("preserved Claude-specific override(s): impeccable")
        })
        XCTAssertNil(try doctorProjectionIssue(root))
    }

    func testReportsConflictingSymlinkWithoutReplacingIt() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-projection")
        let canonical = root.appendingPathComponent(".agents/skills/demo")
        let external = try makeTemporaryRoot(prefix: "metagent-claude-external")
        try writeSkillFixture(at: canonical, name: "demo")
        try writeSkillFixture(at: external.appendingPathComponent("demo"), name: "demo")
        let claudeSkills = root.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        let conflicting = claudeSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(
            at: conflicting,
            withDestinationURL: external.appendingPathComponent("demo")
        )

        let lines = try repair(root, apply: true)

        XCTAssertTrue(symlink(conflicting, resolvesTo: external.appendingPathComponent("demo")))
        XCTAssertTrue(lines.contains {
            $0.kind == .skipped && $0.text.contains("collision(s) left untouched: demo")
        })
        let issue = try XCTUnwrap(doctorProjectionIssue(root))
        XCTAssertNil(issue.repairAction)
        XCTAssertEqual(issue.summary, "Claude skill names collide")
    }

    func testKeepsLegacyWholeFolderProjection() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-projection")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/demo"), name: "demo")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        let claudeSkills = root.appendingPathComponent(".claude/skills")
        try FileManager.default.createSymbolicLink(
            atPath: claudeSkills.path,
            withDestinationPath: "../.agents/skills"
        )

        let lines = try repair(root, apply: true)

        XCTAssertTrue(symlink(claudeSkills, resolvesTo: root.appendingPathComponent(".agents/skills")))
        XCTAssertTrue(lines.contains {
            $0.kind == .info && $0.text.contains("legacy .claude/skills")
        })
        XCTAssertNil(try doctorProjectionIssue(root))
    }

    func testDoctorOffersRepairForMissingPersonalLinks() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-projection")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/personal"), name: "personal")

        let issue = try XCTUnwrap(doctorProjectionIssue(root))

        XCTAssertEqual(issue.repairAction, .repairProjection)
        XCTAssertEqual(issue.summary, "Claude is missing personal skills")
    }

    func testDoctorIgnoresMissingSkillsCLIProjection() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-projection")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/managed"), name: "managed")
        try writeSkillsLock(root, names: ["managed"])

        XCTAssertNil(try doctorProjectionIssue(root))
        let lines = try repair(root, apply: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude").path))
        XCTAssertFalse(lines.contains { $0.kind == .action })
    }

    func testRemovesOnlyOrphanedPersonalProjectionLinks() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-projection")
        let removedSkill = root.appendingPathComponent(".agents/skills/removed")
        try writeSkillFixture(at: removedSkill, name: "removed")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/kept"), name: "kept")
        _ = try repair(root, apply: true)
        let orphanedLink = root.appendingPathComponent(".claude/skills/removed")
        XCTAssertTrue(isSymlink(orphanedLink))

        try FileManager.default.removeItem(at: removedSkill)

        let preview = try repair(root, apply: false)
        XCTAssertTrue(preview.contains {
            $0.kind == .action && $0.text == "would remove orphaned personal Claude link: removed"
        })
        let issue = try XCTUnwrap(doctorProjectionIssue(root))
        XCTAssertEqual(issue.summary, "Claude has stale personal skill links")

        let applied = try repair(root, apply: true)
        XCTAssertFalse(isSymlink(orphanedLink))
        XCTAssertTrue(applied.contains {
            $0.kind == .action && $0.text == "removed orphaned personal Claude link: removed"
        })
    }

    func testLeavesOrphanedSkillsCLIProjectionAlone() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-projection")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/kept"), name: "kept")
        try writeSkillsLock(root, names: ["managed"])
        let claudeSkills = root.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        let managedLink = claudeSkills.appendingPathComponent("managed")
        try FileManager.default.createSymbolicLink(
            atPath: managedLink.path,
            withDestinationPath: "../../.agents/skills/managed"
        )

        let lines = try repair(root, apply: true)

        XCTAssertTrue(isSymlink(managedLink))
        XCTAssertFalse(lines.contains { $0.text.contains("managed") })
    }

    func testUnreadableSkillsLockFailsClosed() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-claude-projection")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/personal"), name: "personal")
        try Data("{not-json".utf8).write(to: root.appendingPathComponent("skills-lock.json"))

        let lines = try repair(root, apply: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude").path))
        XCTAssertTrue(lines.contains {
            $0.kind == .skipped && $0.text.contains("skills-lock.json is unreadable")
        })
        let issue = try XCTUnwrap(doctorProjectionIssue(root))
        XCTAssertEqual(issue.summary, "Skills CLI ownership is unreadable")
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

    private func writeSkillsLock(_ root: URL, names: [String]) throws {
        let skills = Dictionary(uniqueKeysWithValues: names.map { name in
            (
                name,
                [
                    "source": "example/\(name)",
                    "sourceType": "github",
                    "skillPath": "skills/\(name)/SKILL.md",
                    "computedHash": "fixture"
                ]
            )
        })
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "skills": skills],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: root.appendingPathComponent("skills-lock.json"))
    }
}
