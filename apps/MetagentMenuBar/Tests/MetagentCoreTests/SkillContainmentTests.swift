import Foundation
import XCTest
@testable import MetagentCore

final class SkillContainmentTests: XCTestCase {
    func testManagedRemovalCompletesSharedCanonicalRetentionWithoutTouchingOtherProviders() throws {
        let fixture = try makeTemporaryRoot(prefix: "metagent-managed-shared").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let keys = ["HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "METAGENT_NPX", "XDG_STATE_HOME"]
        let previous = keys.map { ProcessInfo.processInfo.environment[$0] }
        defer { for (key, value) in zip(keys, previous) { restoreEnvironment(key, value) } }
        unsetenv("CODEX_HOME")
        unsetenv("CLAUDE_CONFIG_DIR")
        unsetenv("XDG_STATE_HOME")
        // Model Skills CLI's successful scoped removal: Claude's projection is
        // removed, but another detected app keeps the canonical bundle and lock.
        let command = fixture.appendingPathComponent("npx-fixture")
        try "#!/bin/sh\nrm -f \"$PWD/.claude/skills/demo\"\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        setenv("METAGENT_NPX", command.path, 1)

        for (index, useBatch) in [false, true].enumerated() {
            for global in [false, true] {
                let home = fixture.appendingPathComponent("home-\(index)-\(global)")
                let project = global ? home : home.appendingPathComponent("project")
                setenv("HOME", home.path, 1)
                try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
                let canonical = project.appendingPathComponent(".agents/skills/demo")
                try writeSkillFixture(at: canonical, name: "demo")
                let lock = global ? home.appendingPathComponent(".agents/.skill-lock.json")
                    : project.appendingPathComponent("skills-lock.json")
                try #"{"version":1,"futureRoot":true,"skills":{"demo":{"source":"example/skills","sourceType":"github"},"keep":{"source":"example/keep","future":true}}}"#
                    .write(to: lock, atomically: true, encoding: .utf8)
                let claude = project.appendingPathComponent(".claude/skills/demo")
                try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: canonical)
                let independent = project.appendingPathComponent(".cursor/skills/demo")
                try writeSkillFixture(at: independent, name: "demo", body: "Independent sentinel.")

                let report: SkillUninstallReport
                if useBatch {
                    let batch = MetagentCore.removeSkills(targets: [.canonical(projectRoot: project.path, skillName: "demo")], apply: true)
                    XCTAssertTrue(batch.failures.isEmpty, batch.lines.joined(separator: "\n"))
                    report = try XCTUnwrap(batch.reports.first)
                } else {
                    report = try MetagentCore.uninstallSkill(projectRoot: project.path, skillName: "demo", allowManagedRemoval: true)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: claude.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: independent.appendingPathComponent("SKILL.md").path))
                let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: lock)) as? [String: Any])
                XCTAssertEqual(document["futureRoot"] as? Bool, true)
                let skills = try XCTUnwrap(document["skills"] as? [String: Any])
                XCTAssertNil(skills["demo"])
                XCTAssertEqual((skills["keep"] as? [String: Any])?["future"] as? Bool, true)
                let recovery = URL(fileURLWithPath: try XCTUnwrap(report.backupPath))
                XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("demo/SKILL.md").path))
            }
        }
    }

    func testManagedRemovalRefusesLinkedProviderContainersBeforeDispatch() throws {
        let fixture = try makeTemporaryRoot(prefix: "metagent-managed-provider").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let previousNpx = ProcessInfo.processInfo.environment["METAGENT_NPX"]
        defer { restoreEnvironment("METAGENT_NPX", previousNpx) }
        let marker = fixture.appendingPathComponent("manager-invoked")
        let command = fixture.appendingPathComponent("npx-fixture")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        setenv("METAGENT_NPX", command.path, 1)

        for path in [".codex", ".claude", ".codex/skills", ".claude/skills"] {
            let project = fixture.appendingPathComponent(UUID().uuidString)
            let external = fixture.appendingPathComponent(UUID().uuidString)
            try writeSkillFixture(at: project.appendingPathComponent(".agents/skills/demo"), name: "demo")
            let externalSkill = external.appendingPathComponent(path.hasSuffix("/skills") ? "demo" : "skills/demo")
            try writeSkillFixture(at: externalSkill, name: "demo", body: "External sentinel.")
            let link = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)

            XCTAssertThrowsError(try runSkillsCLIRemoval(root: project, skillNames: ["demo", "second"]))
            XCTAssertThrowsError(try runDotagentsRemoval(root: project, skillName: "demo"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: externalSkill.appendingPathComponent("SKILL.md").path))
        }
    }

    func testGlobalManagedRemovalRefusesOtherConfiguredProviderDirectories() throws {
        let fixture = try makeTemporaryRoot(prefix: "metagent-managed-global").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let keys = ["HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "METAGENT_NPX"]
        let previous = keys.map { ProcessInfo.processInfo.environment[$0] }
        defer { for (key, value) in zip(keys, previous) { restoreEnvironment(key, value) } }
        try writeSkillFixture(at: fixture.appendingPathComponent(".agents/skills/demo"), name: "demo")
        let marker = fixture.appendingPathComponent("manager-invoked")
        let command = fixture.appendingPathComponent("npx-fixture")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        setenv("HOME", fixture.path, 1)
        setenv("METAGENT_NPX", command.path, 1)
        for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
            unsetenv("CODEX_HOME")
            unsetenv("CLAUDE_CONFIG_DIR")
            setenv(key, fixture.appendingPathComponent("another-provider").path, 1)
            XCTAssertThrowsError(try runSkillsCLIRemoval(root: fixture, skillName: "demo"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testManagedRemovalKeepsCanonicalCollectionAliasAndScopesSkillsCLI() throws {
        let fixture = try makeTemporaryRoot(prefix: "metagent-managed-scope").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let previousNpx = ProcessInfo.processInfo.environment["METAGENT_NPX"]
        defer { restoreEnvironment("METAGENT_NPX", previousNpx) }
        let project = fixture.appendingPathComponent("project")
        try writeSkillFixture(at: project.appendingPathComponent(".agents/skills/demo"), name: "demo")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent(".claude/skills"),
            withDestinationURL: project.appendingPathComponent(".agents/skills"))
        let capture = fixture.appendingPathComponent("arguments")
        let command = fixture.appendingPathComponent("npx-fixture")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(capture.path)'\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        setenv("METAGENT_NPX", command.path, 1)

        _ = try runSkillsCLIRemoval(root: project, skillNames: ["demo", "second"])

        let arguments = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments, ["--yes", "skills", "remove", "demo", "second", "--yes",
            "--agent", "codex", "claude-code"])
    }

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
