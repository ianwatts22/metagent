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

    /// The entrance must land exactly where the old direct `uninstallSkill`
    /// call landed: same on-disk result, same report text.
    func testEntranceMatchesDirectCanonicalRemoval() throws {
        let home = try fixtureRoot("equivalence-home")
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer { restoreEnvironment("HOME", originalHome) }

        let direct = try canonicalFixture("equivalence-direct")
        let entrance = try canonicalFixture("equivalence-entrance")

        let directReport = try MetagentCore.uninstallSkill(
            projectRoot: direct.path,
            skillName: "demo"
        )
        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: entrance.path,
            skillName: "demo"
        ))
        let batch = MetagentCore.removeSkills(targets: [target], apply: true)

        let outcome = try XCTUnwrap(batch.outcomes.first)
        XCTAssertTrue(outcome.succeeded)
        let entranceReport = try XCTUnwrap(outcome.report)
        XCTAssertEqual(outcome.lines, entranceReport.lines)
        XCTAssertEqual(outcome.backupPath, entranceReport.backupPath)
        XCTAssertEqual(entranceReport.skillName, directReport.skillName)
        XCTAssertEqual(entranceReport.projectRoot, entrance.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            try recoveryNeutralLines(entranceReport),
            try recoveryNeutralLines(directReport)
        )
        XCTAssertTrue(entranceReport.lines.contains("removed 1 per-skill projection link(s)"))
        XCTAssertTrue(entranceReport.lines.contains(
            "kept 1 independent same-name legacy location(s); review them separately"
        ))
        XCTAssertTrue(entranceReport.lines.contains("verified canonical local skill is absent"))

        let fileManager = FileManager.default
        for root in [direct, entrance] {
            XCTAssertFalse(fileManager.fileExists(
                atPath: root.appendingPathComponent(".agents/skills/demo").path
            ))
            XCTAssertNil(try? fileManager.attributesOfItem(
                atPath: root.appendingPathComponent(".claude/skills/demo").path
            ))
            XCTAssertTrue(fileManager.fileExists(
                atPath: root.appendingPathComponent(".codex/skills/demo/SKILL.md").path
            ))
        }
        for report in [directReport, entranceReport] {
            let recovery = URL(fileURLWithPath: try XCTUnwrap(report.backupPath))
            XCTAssertTrue(fileManager.fileExists(
                atPath: recovery.appendingPathComponent("demo/SKILL.md").path
            ))
            XCTAssertNotNil(try? fileManager.attributesOfItem(
                atPath: recovery.appendingPathComponent("projections/0-claude/demo").path
            ))
            for snapshot in ["before.json", "after.json", "REMOVAL.txt"] {
                XCTAssertTrue(fileManager.fileExists(
                    atPath: recovery.appendingPathComponent(snapshot).path
                ))
            }
        }
    }

    private func fixtureRoot(_ label: String) throws -> URL {
        try makeTemporaryRoot(prefix: "metagent-removal-\(label)")
    }

    private func writeSkill(named name: String, under directory: URL) throws {
        try writeSkillFixture(at: directory.appendingPathComponent(name), name: name)
    }

    /// A canonical local skill with one projection link and one independent
    /// same-name copy, so a removal exercises every report line.
    private func canonicalFixture(_ label: String) throws -> URL {
        let root = try fixtureRoot(label)
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))
        try writeSkill(named: "demo", under: root.appendingPathComponent(".codex/skills"))
        let projections = root.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: projections, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: projections.appendingPathComponent("demo").path,
            withDestinationPath: "../../.agents/skills/demo"
        )
        return root
    }

    /// Report lines with the per-removal recovery folder folded away, so two
    /// removals of identical fixtures compare equal.
    private func recoveryNeutralLines(_ report: SkillUninstallReport) throws -> [String] {
        let recovery = try XCTUnwrap(report.backupPath)
        return report.lines.map { $0.replacingOccurrences(of: recovery, with: "<recovery>") }
    }
}
