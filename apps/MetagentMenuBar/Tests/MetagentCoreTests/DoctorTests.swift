import Foundation
import XCTest
@testable import MetagentCore

final class DoctorTests: XCTestCase {
    func testProjectionRepairRemovesOnlyObsoleteCodexSymlinks() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-doctor-tests")
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let codexSkills = root.appendingPathComponent(".codex/skills")
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try writeSkillFixture(at: skill, description: "Demo")
        let projection = codexSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)

        let project = try XCTUnwrap(try scan(root).projects.first)
        let preview = try repairProjectProjection(project, apply: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: projection.path))
        XCTAssertTrue(preview.contains {
            $0.kind == .action && $0.text == "would remove obsolete Codex link: \(projection.path)"
        })

        let applied = try repairProjectProjection(project, apply: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: projection.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(applied.contains {
            $0.kind == .action && $0.text == "removed obsolete Codex link: \(projection.path)"
        })
    }

    func testRepairApplyRemovesOnlyPathsApprovedByPreview() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-doctor-tests")
        let firstSkill = root.appendingPathComponent(".agents/skills/first")
        let codexSkills = root.appendingPathComponent(".codex/skills")
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try writeSkillFixture(at: firstSkill, name: "first", description: "First")
        let firstProjection = codexSkills.appendingPathComponent("first")
        try FileManager.default.createSymbolicLink(at: firstProjection, withDestinationURL: firstSkill)

        let scanOptions = makeScanOptions(root)
        let preview = try MetagentCore.repairSkills(options: SkillsRepairOptions(scanOptions: scanOptions))
        XCTAssertEqual(preview.projects.flatMap(\.plannedCodexProjectionPaths), [firstProjection.path])

        let secondSkill = root.appendingPathComponent(".agents/skills/second")
        try writeSkillFixture(at: secondSkill, name: "second", description: "Second")
        let secondProjection = codexSkills.appendingPathComponent("second")
        try FileManager.default.createSymbolicLink(at: secondProjection, withDestinationURL: secondSkill)

        _ = try MetagentCore.repairSkills(options: SkillsRepairOptions(
            apply: true,
            scanOptions: scanOptions,
            approvedCodexProjectionPaths: [firstProjection.path]
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstProjection.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondProjection.path))
    }

    func testRepairApplyScopesApprovedPathsToExactNestedProject() throws {
        let parent = try makeTemporaryRoot(prefix: "metagent-doctor-parent")
        let child = parent.appendingPathComponent("child")

        let parentSkill = parent.appendingPathComponent(".agents/skills/parent-skill")
        let childSkill = child.appendingPathComponent(".agents/skills/child-skill")
        let parentCodexSkills = parent.appendingPathComponent(".codex/skills")
        let childCodexSkills = child.appendingPathComponent(".codex/skills")
        for directory in [parentCodexSkills, childCodexSkills] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeSkillFixture(at: parentSkill, name: "parent-skill", description: "Parent")
        try writeSkillFixture(at: childSkill, name: "child-skill", description: "Child")

        let parentProjection = parentCodexSkills.appendingPathComponent("parent-skill")
        let childProjection = childCodexSkills.appendingPathComponent("child-skill")
        try FileManager.default.createSymbolicLink(at: parentProjection, withDestinationURL: parentSkill)
        try FileManager.default.createSymbolicLink(at: childProjection, withDestinationURL: childSkill)

        _ = try MetagentCore.repairSkills(options: SkillsRepairOptions(
            apply: true,
            scanOptions: SkillScanOptions(
                roots: [parent.path, child.path],
                maxDepth: 0,
                respectConfiguredIgnores: false
            ),
            approvedCodexProjectionPaths: [childProjection.path]
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: parentProjection.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: childProjection.path))
    }

    func testRepairApplyKeepsNestedProjectionInExactProjectPlan() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-doctor-nested-link")
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let codexGroup = root.appendingPathComponent(".codex/skills/group")
        try FileManager.default.createDirectory(at: codexGroup, withIntermediateDirectories: true)
        try writeSkillFixture(at: skill, description: "Demo")
        let projection = codexGroup.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)

        let scanOptions = makeScanOptions(root)
        let preview = try MetagentCore.repairSkills(options: SkillsRepairOptions(scanOptions: scanOptions))
        XCTAssertEqual(preview.projects.flatMap(\.plannedCodexProjectionPaths), [projection.path])

        _ = try MetagentCore.repairSkills(options: SkillsRepairOptions(
            apply: true,
            scanOptions: scanOptions,
            approvedCodexProjectionPaths: preview.projects.flatMap(\.plannedCodexProjectionPaths),
            approvedActionsByProject: preview.actionsByProject
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: projection.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path))
    }

    func testRepairApplyPreservesConflictingClaudeLinkWhileRemovingApprovedCodexLink() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-doctor-plan")
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let codexSkills = root.appendingPathComponent(".codex/skills")
        let claudeDirectory = root.appendingPathComponent(".claude")
        let claudeSkills = claudeDirectory.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try writeSkillFixture(at: skill, description: "Demo")
        let projection = codexSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)
        try FileManager.default.createSymbolicLink(
            atPath: claudeSkills.path,
            withDestinationPath: "../.agents/skills"
        )

        let scanOptions = makeScanOptions(root)
        let preview = try MetagentCore.repairSkills(options: SkillsRepairOptions(scanOptions: scanOptions))
        try FileManager.default.removeItem(at: claudeSkills)
        try FileManager.default.createSymbolicLink(
            atPath: claudeSkills.path,
            withDestinationPath: "../wrong-skills"
        )

        _ = try MetagentCore.repairSkills(options: SkillsRepairOptions(
            apply: true,
            scanOptions: scanOptions,
            approvedCodexProjectionPaths: preview.projects.flatMap(\.plannedCodexProjectionPaths),
            approvedActionsByProject: preview.actionsByProject
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projection.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: claudeSkills.path),
            "../wrong-skills"
        )
    }

    func testProjectionRepairPreservesExternalCodexSymlink() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-doctor-tests")
        let external = try makeTemporaryRoot(prefix: "metagent-doctor-external")
        let externalSkill = external.appendingPathComponent("demo")
        let codexSkills = root.appendingPathComponent(".codex/skills")
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try writeSkillFixture(at: externalSkill, description: "Demo")
        let projection = codexSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: externalSkill)

        let project = try XCTUnwrap(try scan(root).projects.first)
        let preview = try repairProjectProjection(project, apply: false)

        XCTAssertFalse(preview.contains { $0.text.contains("obsolete .codex") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: projection.path))
    }

    func testProjectionRepairDoesNotRemoveCodexLinksWhenClaudeRepairFails() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-doctor-tests")
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let codexSkills = root.appendingPathComponent(".codex/skills")
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try writeSkillFixture(at: skill, description: "Demo")
        let projection = codexSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)
        try Data("not a directory".utf8).write(to: root.appendingPathComponent(".claude"))

        let project = try XCTUnwrap(try scan(root).projects.first)

        XCTAssertThrowsError(try repairProjectProjection(project, apply: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projection.path))
    }

    func testProjectionRepairIgnoresSymlinkedCodexSkillsContainer() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-doctor-tests")
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let codexRoot = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try writeSkillFixture(at: skill, description: "Demo")
        let codexSkills = codexRoot.appendingPathComponent("skills")
        try FileManager.default.createSymbolicLink(
            at: codexSkills,
            withDestinationURL: root.appendingPathComponent(".agents/skills")
        )

        let project = try XCTUnwrap(try scan(root).projects.first)
        let preview = try repairProjectProjection(project, apply: false)

        XCTAssertFalse(preview.contains { $0.text.contains("obsolete .codex") })
        XCTAssertTrue((try? FileManager.default.destinationOfSymbolicLink(atPath: codexSkills.path)) != nil)
    }

    func testProjectionRepairIgnoresSymlinkedCodexDirectory() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-doctor-tests")
        let externalCodex = try makeTemporaryRoot(prefix: "metagent-doctor-external-codex")
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let externalSkills = externalCodex.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: externalSkills, withIntermediateDirectories: true)
        try writeSkillFixture(at: skill, description: "Demo")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".codex"),
            withDestinationURL: externalCodex
        )
        let projection = externalSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)

        let project = try XCTUnwrap(try scan(root).projects.first)
        let preview = try repairProjectProjection(project, apply: false)

        XCTAssertFalse(preview.contains { $0.text.contains("obsolete .codex") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: projection.path))
    }

    func testRepairPreviewExcludesNoOpHomeInventory() throws {
        let root = try makeTemporaryRoot(prefix: "metagent-doctor-home")
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", root.path, 1)
        defer { restoreEnvironment("HOME", originalHome) }
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/demo"), description: "Demo")

        let preview = try MetagentCore.repairSkills()

        XCTAssertFalse(preview.projects.contains { $0.root == root.path })
    }

    private func makeScanOptions(_ root: URL) -> SkillScanOptions {
        SkillScanOptions(
            roots: [root.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        )
    }

    private func scan(_ root: URL) throws -> SkillScanReport {
        try MetagentCore.scanSkills(options: makeScanOptions(root))
    }
}
