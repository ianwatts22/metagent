import Foundation
import XCTest
@testable import MetagentCore

final class SkillRemovalRoutingTests: XCTestCase {
    func testResolvesCanonicalAgentsSkill() throws {
        let root = try fixtureRoot("canonical")
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))

        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))

        XCTAssertEqual(target.method, .canonical)
        XCTAssertEqual(target.skillName, "demo")
        XCTAssertEqual(target.displayName, "demo")
        XCTAssertEqual(target.id, "canonical:\(root.resolvingSymlinksInPath().path):demo")
        XCTAssertNil(target.skillPath)
    }

    func testResolvesStandaloneCodexSkill() throws {
        let root = try fixtureRoot("standalone")
        try writeSkill(named: "demo", under: root.appendingPathComponent(".codex/skills"))

        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))

        XCTAssertEqual(target.method, .standalone)
        XCTAssertEqual(target.skillName, "demo")
        XCTAssertEqual(
            target.skillPath,
            root.resolvingSymlinksInPath().appendingPathComponent(".codex/skills/demo").path
        )
        XCTAssertEqual(target.id, "standalone:\(try XCTUnwrap(target.skillPath))")
    }

    func testResolvesCodexPluginSkill() throws {
        let root = try fixtureRoot("plugin")
        let skill = SkillInventoryItem.fixture(
            name: "demo",
            path: root.appendingPathComponent("skills/demo").path,
            location: "plugin",
            locationLabel: "plugin",
            manager: "codex-plugin",
            authority: "openai/tools@marketplace",
            mutability: "managed-read-only"
        )

        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skill: skill,
            variants: [skill]
        ))

        XCTAssertEqual(target.method, .codexPlugin)
        XCTAssertEqual(target.pluginID, "openai/tools@marketplace")
        XCTAssertEqual(target.id, "plugin:openai/tools@marketplace")
        XCTAssertEqual(target.displayName, "openai/tools@marketplace plugin")
    }

    func testCanonicalOwnershipWinsOverStandaloneVariant() throws {
        let root = try fixtureRoot("precedence")
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))
        try writeSkill(named: "demo", under: root.appendingPathComponent(".codex/skills"))

        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))

        XCTAssertEqual(target.method, .canonical)
    }

    func testResolvesNoTargetForUnknownSkillOrUnownedVariant() throws {
        let root = try fixtureRoot("no-target")
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))

        XCTAssertNil(try MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "missing"
        ))

        let projection = SkillInventoryItem.fixture(
            name: "demo",
            path: root.appendingPathComponent(".claude/skills/demo").path,
            location: "claude",
            locationLabel: ".claude",
            manager: "claude",
            representation: "projection"
        )
        XCTAssertNil(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skill: projection,
            variants: [projection]
        ))
    }

    func testDryRunPlansWithoutMutating() throws {
        let root = try fixtureRoot("dry-run")
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))

        let report = MetagentCore.removeSkills(targets: [target])

        XCTAssertFalse(report.apply)
        XCTAssertEqual(report.outcomes.count, 1)
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertNil(outcome.report)
        let plan = try XCTUnwrap(outcome.plan)
        XCTAssertEqual(plan.method, .canonical)
        XCTAssertEqual(plan.manager, "local")
        XCTAssertEqual(plan.mutability, "editable")
        XCTAssertNil(plan.command)
        XCTAssertTrue(plan.applySupported)
        XCTAssertEqual(plan.targetID, target.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path))
    }

    func testDryRunReportsUnsupportedStandaloneTarget() throws {
        let root = try fixtureRoot("dry-run-standalone")
        let external = try fixtureRoot("dry-run-external")
        try writeSkill(named: "demo", under: external.appendingPathComponent("skills"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".codex"),
            withDestinationURL: external
        )
        let target = SkillRemovalTarget.standalone(
            projectRoot: root.path,
            skillPath: root.appendingPathComponent(".codex/skills/demo").path,
            skillName: "demo"
        )

        let report = MetagentCore.removeSkills(targets: [target])

        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(try XCTUnwrap(outcome.plan).applySupported)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: external.appendingPathComponent("skills/demo/SKILL.md").path
        ))
    }

    func testApplyBatchesCanonicalSkillsPerProjectRoot() throws {
        let home = try fixtureRoot("apply-home")
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer { restoreEnvironment("HOME", originalHome) }

        let first = try fixtureRoot("apply-first")
        let second = try fixtureRoot("apply-second")
        try writeSkill(named: "alpha", under: first.appendingPathComponent(".agents/skills"))
        try writeSkill(named: "beta", under: first.appendingPathComponent(".agents/skills"))
        try writeSkill(named: "gamma", under: second.appendingPathComponent(".agents/skills"))
        let targets = try [
            XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(projectRoot: first.path, skillName: "alpha")),
            XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(projectRoot: first.path, skillName: "beta")),
            XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(projectRoot: second.path, skillName: "gamma")),
        ]
        XCTAssertEqual(Set(targets.compactMap(\.projectRoot)).count, 2)

        let report = MetagentCore.removeSkills(targets: targets, apply: true)

        XCTAssertTrue(report.apply)
        XCTAssertEqual(report.succeededIDs, Set(targets.map(\.id)))
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.reports.count, 3)
        for skill in ["alpha", "beta"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: first.appendingPathComponent(".agents/skills/\(skill)").path
            ))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: second.appendingPathComponent(".agents/skills/gamma").path
        ))
        XCTAssertEqual(report.lines.prefix(1), ["alpha:"])
        for report in report.reports {
            let recovery = URL(fileURLWithPath: try XCTUnwrap(report.backupPath))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: recovery.appendingPathComponent("\(report.skillName)/SKILL.md").path
            ))
        }
    }

    func testApplyDeduplicatesTargetsAndReportsFailures() throws {
        let home = try fixtureRoot("failure-home")
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer { restoreEnvironment("HOME", originalHome) }

        let root = try fixtureRoot("failure")
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))
        let present = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))
        let missing = SkillRemovalTarget.canonical(projectRoot: root.path, skillName: "absent")

        let report = MetagentCore.removeSkills(
            targets: [present, present, missing],
            apply: true
        )

        XCTAssertEqual(report.outcomes.count, 2)
        XCTAssertEqual(report.succeededIDs, [present.id])
        XCTAssertEqual(report.failedIDs, [missing.id])
        XCTAssertEqual(report.failures.map(\.skillName), ["absent"])
        XCTAssertTrue(report.lines.contains("absent: failed"))
    }

    private func fixtureRoot(_ label: String) throws -> URL {
        try makeTemporaryRoot(prefix: "metagent-removal-\(label)")
    }

    private func writeSkill(named name: String, under directory: URL) throws {
        try writeSkillFixture(at: directory.appendingPathComponent(name), name: name)
    }
}
