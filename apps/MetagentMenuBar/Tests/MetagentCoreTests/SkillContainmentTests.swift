import Foundation
import XCTest
@testable import MetagentCore

final class SkillContainmentTests: XCTestCase {
    func testSavedLifecycleTargetCannotReselectReplacedProjectRoot() throws {
        let fixture = try makeTemporaryRoot(prefix: "metagent-root-replay").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let project = fixture.appendingPathComponent("project")
        let external = fixture.appendingPathComponent("external")
        try writeSkillFixture(at: project.appendingPathComponent(".agents/skills/demo"), name: "demo")
        try writeSkillFixture(at: external.appendingPathComponent(".agents/skills/demo"), name: "demo", body: "External sentinel.")
        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(projectRoot: project.path, skillName: "demo"))
        try FileManager.default.moveItem(at: project, to: fixture.appendingPathComponent("retained-project"))
        try FileManager.default.createSymbolicLink(at: project, withDestinationURL: external)

        XCTAssertFalse(MetagentCore.removeSkills(targets: [target], apply: true).outcomes.allSatisfy(\.succeeded))
        XCTAssertFalse(MetagentCore.archiveSkills(targets: [target], apply: true).outcomes.allSatisfy(\.succeeded))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent(".agents/skills/demo/SKILL.md").path))
    }

    func testRemovalLeavesNestedExternalProjectionAndRemovesOrdinaryProjection() throws {
        let fixture = try makeTemporaryRoot(prefix: "metagent-nested-provider")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", fixture.path, 1)
        defer { restoreEnvironment("HOME", previousHome) }
        let project = fixture.appendingPathComponent("project")
        let skill = project.appendingPathComponent(".agents/skills/demo")
        let provider = project.appendingPathComponent(".claude/skills")
        let external = fixture.appendingPathComponent("external")
        try writeSkillFixture(at: skill, name: "demo")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let outsideProjection = external.appendingPathComponent("demo")
        let ordinaryProjection = provider.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: outsideProjection, withDestinationURL: skill)
        try FileManager.default.createSymbolicLink(at: ordinaryProjection, withDestinationURL: skill)
        try FileManager.default.createSymbolicLink(at: provider.appendingPathComponent("nested"), withDestinationURL: external)
        let inventory = try readProjectSkills(root: project)
        let linked = try XCTUnwrap(inventory.skills.first { $0.path.contains("/nested/demo") })
        XCTAssertTrue(linked.symlinkedContainer)

        _ = try MetagentCore.uninstallSkill(projectRoot: project.path, skillName: "demo")

        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: outsideProjection.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: ordinaryProjection.path))
        let recovery = fixture.appendingPathComponent("managed-recovery")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        var lines: [String] = []
        finishManagedSkillRemoval(manager: "skills-cli", projections: [linked], recovery: recovery,
            projectRoot: project.resolvingSymlinksInPath(), skillName: "demo", lines: &lines)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: outsideProjection.path))
        XCTAssertTrue(lines.contains { $0.hasPrefix("warning: left projection") })
    }

    func testContainmentChecksMissingPathsAndLinksBelowResolvedRoot() throws {
        let fixture = try makeTemporaryRoot(prefix: "metagent-path-containment").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(isUnsymlinkedDescendant(root.appendingPathComponent("missing/nested/demo"), of: root))
        XCTAssertFalse(isUnsymlinkedDescendant(fixture.appendingPathComponent("project-neighbor/demo"), of: root))
        for name in ["linked", "dangling"] {
            let target = fixture.appendingPathComponent(name == "linked" ? "external" : "absent")
            if name == "linked" {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
            let link = root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertFalse(isUnsymlinkedDescendant(link, of: root))
            XCTAssertFalse(isUnsymlinkedDescendant(link.appendingPathComponent("skills/demo"), of: root))
        }
        let alias = fixture.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let selectedRoot = alias.resolvingSymlinksInPath()
        XCTAssertTrue(isUnsymlinkedDescendant(selectedRoot.appendingPathComponent("skills/demo"), of: selectedRoot))
    }

    func testStaleLifecycleTargetAndRestoreRefuseReplacedAncestor() throws {
        let fixture = try makeTemporaryRoot(prefix: "metagent-stale-containment")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", fixture.path, 1)
        defer { restoreEnvironment("HOME", previousHome) }
        let project = fixture.appendingPathComponent("project")
        let external = fixture.appendingPathComponent("external")
        try writeSkillFixture(at: project.appendingPathComponent(".agents/skills/demo"), name: "demo")
        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(projectRoot: project.path, skillName: "demo"))
        XCTAssertTrue(MetagentCore.archiveSkills(targets: [target], apply: true).outcomes.allSatisfy(\.succeeded))
        let archived = try XCTUnwrap(MetagentCore.listArchivedSkills().first)
        try FileManager.default.moveItem(at: project.appendingPathComponent(".agents"), to: fixture.appendingPathComponent("retained-agents"))
        try FileManager.default.createDirectory(at: external.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(".agents"), withDestinationURL: external)
        XCTAssertThrowsError(try MetagentCore.restoreArchivedSkill(named: "demo"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: try XCTUnwrap(archived.archivePath)).appendingPathComponent("demo/SKILL.md").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.appendingPathComponent("skills").path).isEmpty)

        try writeSkillFixture(at: external.appendingPathComponent("skills/demo"), name: "demo")
        XCTAssertThrowsError(try MetagentCore.uninstallSkill(projectRoot: project.path, skillName: "demo"))
        XCTAssertFalse(MetagentCore.archiveSkills(targets: [target], apply: true).outcomes.allSatisfy(\.succeeded))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("skills/demo/SKILL.md").path))
    }

    func testCanonicalRemovalLeavesProjectionBehindLinkedProviderAncestor() throws {
        let fixture = try makeTemporaryRoot(prefix: "metagent-provider-containment")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", fixture.path, 1)
        defer { restoreEnvironment("HOME", previousHome) }
        let project = fixture.appendingPathComponent("project")
        let skill = project.appendingPathComponent(".agents/skills/demo")
        let external = fixture.appendingPathComponent("external")
        try writeSkillFixture(at: skill, name: "demo")
        try FileManager.default.createDirectory(at: external.appendingPathComponent("skills"), withIntermediateDirectories: true)
        let projection = external.appendingPathComponent("skills/demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(".claude"), withDestinationURL: external)
        _ = try MetagentCore.uninstallSkill(projectRoot: project.path, skillName: "demo")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: projection.path))
    }

    func testSymlinkedAgentsAncestorIsReadOnlyAndCannotRemoveOrArchiveExternalSkill() throws {
        let fixture = try makeTemporaryRoot(prefix: "metagent-lifecycle-containment")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", fixture.path, 1)
        defer { restoreEnvironment("HOME", previousHome) }
        let project = fixture.appendingPathComponent("project")
        let external = fixture.appendingPathComponent("external")
        let externalSkill = external.appendingPathComponent("skills/demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeSkillFixture(at: externalSkill, name: "demo", body: "Keep this external bundle.")
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent(".agents"), withDestinationURL: external
        )

        let inventory = try readProjectSkills(root: project)
        let skill = try XCTUnwrap(inventory.skills.first { $0.location == "agents" && $0.name == "demo" })
        XCTAssertEqual(skill.representation, "projection")
        XCTAssertEqual(skill.mutability, "managed-read-only")
        XCTAssertTrue(skill.symlinkedContainer)
        XCTAssertFalse(try MetagentCore.planSkillRemoval(projectRoot: project.path, skillName: "demo").applySupported)
        XCTAssertThrowsError(try MetagentCore.uninstallSkill(projectRoot: project.path, skillName: "demo"))
        let target = SkillRemovalTarget.canonical(projectRoot: project.path, skillName: "demo")
        let archived = MetagentCore.archiveSkills(targets: [target], apply: true)
        XCTAssertFalse(try XCTUnwrap(archived.outcomes.first).succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalSkill.appendingPathComponent("SKILL.md").path))
    }
}
