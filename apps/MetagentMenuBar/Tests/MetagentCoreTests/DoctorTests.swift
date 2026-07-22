import Foundation
import XCTest
@testable import MetagentCore

final class DoctorTests: XCTestCase {
    func testProjectionRepairRemovesOnlyObsoleteCodexSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let codexSkills = root.appendingPathComponent(".codex/skills")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Demo\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
        let projection = codexSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)

        let scan = try MetagentCore.scanSkills(options: SkillScanOptions(
            roots: [root.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        ))
        let project = try XCTUnwrap(scan.projects.first)
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSkill = root.appendingPathComponent(".agents/skills/first")
        let codexSkills = root.appendingPathComponent(".codex/skills")
        try FileManager.default.createDirectory(at: firstSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try Data("---\nname: first\ndescription: First\n---\n".utf8)
            .write(to: firstSkill.appendingPathComponent("SKILL.md"))
        let firstProjection = codexSkills.appendingPathComponent("first")
        try FileManager.default.createSymbolicLink(at: firstProjection, withDestinationURL: firstSkill)

        let scanOptions = SkillScanOptions(
            roots: [root.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        )
        let preview = try MetagentCore.repairSkills(options: SkillsRepairOptions(scanOptions: scanOptions))
        XCTAssertEqual(preview.projects.flatMap(\.plannedCodexProjectionPaths), [firstProjection.path])

        let secondSkill = root.appendingPathComponent(".agents/skills/second")
        try FileManager.default.createDirectory(at: secondSkill, withIntermediateDirectories: true)
        try Data("---\nname: second\ndescription: Second\n---\n".utf8)
            .write(to: secondSkill.appendingPathComponent("SKILL.md"))
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
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-parent-\(UUID().uuidString)")
        let child = parent.appendingPathComponent("child")
        defer { try? FileManager.default.removeItem(at: parent) }

        let parentSkill = parent.appendingPathComponent(".agents/skills/parent-skill")
        let childSkill = child.appendingPathComponent(".agents/skills/child-skill")
        let parentCodexSkills = parent.appendingPathComponent(".codex/skills")
        let childCodexSkills = child.appendingPathComponent(".codex/skills")
        for directory in [parentSkill, childSkill, parentCodexSkills, childCodexSkills] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("---\nname: parent-skill\ndescription: Parent\n---\n".utf8)
            .write(to: parentSkill.appendingPathComponent("SKILL.md"))
        try Data("---\nname: child-skill\ndescription: Child\n---\n".utf8)
            .write(to: childSkill.appendingPathComponent("SKILL.md"))

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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-nested-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let codexGroup = root.appendingPathComponent(".codex/skills/group")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexGroup, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Demo\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
        let projection = codexGroup.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)

        let scanOptions = SkillScanOptions(
            roots: [root.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        )
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

    func testRepairApplyRejectsClaudeChangesAfterPreviewBeforeRemovingCodexLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let codexSkills = root.appendingPathComponent(".codex/skills")
        let claudeDirectory = root.appendingPathComponent(".claude")
        let claudeSkills = claudeDirectory.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Demo\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
        let projection = codexSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)
        try FileManager.default.createSymbolicLink(
            atPath: claudeSkills.path,
            withDestinationPath: "../.agents/skills"
        )

        let scanOptions = SkillScanOptions(
            roots: [root.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        )
        let preview = try MetagentCore.repairSkills(options: SkillsRepairOptions(scanOptions: scanOptions))
        try FileManager.default.removeItem(at: claudeSkills)
        try FileManager.default.createSymbolicLink(
            atPath: claudeSkills.path,
            withDestinationPath: "../wrong-skills"
        )

        XCTAssertThrowsError(try MetagentCore.repairSkills(options: SkillsRepairOptions(
            apply: true,
            scanOptions: scanOptions,
            approvedCodexProjectionPaths: preview.projects.flatMap(\.plannedCodexProjectionPaths),
            approvedActionsByProject: preview.actionsByProject
        )))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projection.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: claudeSkills.path),
            "../wrong-skills"
        )
    }

    func testProjectionRepairPreservesExternalCodexSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-tests-\(UUID().uuidString)")
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-external-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let externalSkill = external.appendingPathComponent("demo")
        let codexSkills = root.appendingPathComponent(".codex/skills")
        try FileManager.default.createDirectory(at: externalSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Demo\n---\n".utf8)
            .write(to: externalSkill.appendingPathComponent("SKILL.md"))
        let projection = codexSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: externalSkill)

        let project = try XCTUnwrap(try scan(root).projects.first)
        let preview = try repairProjectProjection(project, apply: false)

        XCTAssertFalse(preview.contains { $0.text.contains("obsolete .codex") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: projection.path))
    }

    func testProjectionRepairDoesNotRemoveCodexLinksWhenClaudeRepairFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let codexSkills = root.appendingPathComponent(".codex/skills")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexSkills, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Demo\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
        let projection = codexSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: skill)
        try Data("not a directory".utf8).write(to: root.appendingPathComponent(".claude"))

        let project = try XCTUnwrap(try scan(root).projects.first)

        XCTAssertThrowsError(try repairProjectProjection(project, apply: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projection.path))
    }

    func testProjectionRepairIgnoresSymlinkedCodexSkillsContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let codexRoot = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Demo\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-tests-\(UUID().uuidString)")
        let externalCodex = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-external-codex-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalCodex)
        }
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let externalSkills = externalCodex.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSkills, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Demo\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-doctor-home-\(UUID().uuidString)")
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", root.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
            try? FileManager.default.removeItem(at: root)
        }
        let skill = root.appendingPathComponent(".agents/skills/demo")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Demo\n---\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))

        let preview = try MetagentCore.repairSkills()

        XCTAssertFalse(preview.projects.contains { $0.root == root.path })
    }

    private func scan(_ root: URL) throws -> SkillScanReport {
        try MetagentCore.scanSkills(options: SkillScanOptions(
            roots: [root.path],
            maxDepth: 0,
            respectConfiguredIgnores: false
        ))
    }
}
