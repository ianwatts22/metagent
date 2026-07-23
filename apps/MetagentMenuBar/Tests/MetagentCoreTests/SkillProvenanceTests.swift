import Foundation
import XCTest
@testable import MetagentCore

final class SkillProvenanceTests: XCTestCase {
    func testInventoryCapturesSkillMetadataAndManagedUpstream() throws {
        let root = try fixtureRoot("metadata")
        defer { try? FileManager.default.removeItem(at: root) }
        let skillsDirectory = root.appendingPathComponent(".agents/skills")
        try writeSkill(named: "demo", under: skillsDirectory)
        let skillDirectory = skillsDirectory.appendingPathComponent("demo")
        try FileManager.default.createDirectory(
            at: skillDirectory.appendingPathComponent("references"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: skillDirectory.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try "---\nname: nested\ndescription: nested reference\n---\n".write(
            to: skillDirectory.appendingPathComponent("references/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\n".write(
            to: skillDirectory.appendingPathComponent("scripts/check.sh"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "skills": {
            "demo": {
              "source": "example/skill-pack",
              "sourceUrl": "https://github.com/example/skill-pack.git",
              "ref": "v1.2.3",
              "updatedAt": "2026-07-20T12:00:00.000Z"
            }
          }
        }
        """.write(
            to: root.appendingPathComponent("skills-lock.json"),
            atomically: true,
            encoding: .utf8
        )

        let skill = try XCTUnwrap(try scan(root).projects.first?.skills.first)

        XCTAssertEqual(skill.description, "fixture")
        XCTAssertEqual(skill.manager, "skills-cli")
        XCTAssertEqual(skill.source, "example/skill-pack")
        XCTAssertEqual(skill.sourceURL, "https://github.com/example/skill-pack.git")
        XCTAssertEqual(skill.ref, "v1.2.3")
        XCTAssertEqual(skill.updatedAt, "2026-07-20T12:00:00.000Z")
        XCTAssertEqual(skill.referenceFileCount, 1)
        XCTAssertEqual(skill.scriptFileCount, 1)
    }

    func testLocalSkillFallsBackToLatestContentModificationDate() throws {
        let root = try fixtureRoot("modified-date")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))

        let skill = try XCTUnwrap(try scan(root).projects.first?.skills.first)

        XCTAssertNotNil(skill.updatedAt)
        XCTAssertNotNil(skill.updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    func testDotagentsLocalPathUsesManifestAndRepositoryEvidence() throws {
        let root = try fixtureRoot("dotagents")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try """
        [remote "origin"]
          url = https://github.com/example/provenance-fixture.git
        """.write(to: root.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try """
        version = 1

        [[skills]]
        name = "demo" # local display name
        source = "path:.agents/skills/demo" # canonical source
        """.write(to: root.appendingPathComponent("agents.toml"), atomically: true, encoding: .utf8)
        try """
        version = 1

        [skills.demo]
        source = "path:.agents/skills/demo"
        """.write(to: root.appendingPathComponent("agents.lock"), atomically: true, encoding: .utf8)

        let skill = try XCTUnwrap(try scan(root).projects.first?.skills.first { $0.location == "agents" })

        XCTAssertEqual(skill.manager, "dotagents")
        XCTAssertEqual(skill.authority, "repository:\(root.lastPathComponent)")
        XCTAssertEqual(skill.originKind, "dotagents-local")
        XCTAssertEqual(skill.mutability, "editable")
        XCTAssertEqual(skill.sourceType, "dotagents-lock")
        XCTAssertEqual(skill.sourceURL, "https://github.com/example/provenance-fixture.git")
        let removal = try MetagentCore.planSkillRemoval(projectRoot: root.path, skillName: "demo")
        XCTAssertTrue(removal.applySupported)
        XCTAssertEqual(removal.manager, "dotagents")
        XCTAssertEqual(removal.command, "npx --yes @sentry/dotagents remove demo --yes")
    }

    func testRepositoryAndProjectLocalSkillsKeepExplicitOwnership() throws {
        let repository = try fixtureRoot("repository")
        let local = try fixtureRoot("local")
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: local)
        }
        try writeSkill(named: "repo-skill", under: repository.appendingPathComponent(".agents/skills"))
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try writeSkill(named: "local-skill", under: local.appendingPathComponent(".agents/skills"))

        let repositorySkill = try XCTUnwrap(try scan(repository).projects.first?.skills.first)
        let localSkill = try XCTUnwrap(try scan(local).projects.first?.skills.first)

        XCTAssertEqual(repositorySkill.manager, "git")
        XCTAssertEqual(repositorySkill.authority, "repository:\(repository.lastPathComponent)")
        XCTAssertEqual(repositorySkill.originKind, "git-repository")
        XCTAssertEqual(localSkill.manager, "local")
        XCTAssertEqual(localSkill.authority, "project-owned")
        XCTAssertEqual(localSkill.originKind, "project-local")
    }

    func testIndependentClaudeSkillHasNamedManagerAndAuthority() throws {
        let root = try fixtureRoot("claude")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(named: "demo", under: root.appendingPathComponent(".claude/skills"))

        let skill = try XCTUnwrap(try scan(root).projects.first?.skills.first)

        XCTAssertEqual(skill.manager, "claude")
        XCTAssertEqual(skill.authority, "claude-installed")
        XCTAssertEqual(skill.originKind, "claude-installed")
    }

    func testStandaloneRemovalRejectsSymlinkedAgentContainer() throws {
        let root = try fixtureRoot("standalone-removal")
        let external = try fixtureRoot("standalone-external")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let externalSkills = external.appendingPathComponent("skills")
        try writeSkill(named: "demo", under: externalSkills)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".codex"),
            withDestinationURL: external
        )
        let linkedSkill = root.appendingPathComponent(".codex/skills/demo")

        XCTAssertFalse(MetagentCore.canUninstallStandaloneSkill(
            projectRoot: root.path,
            skillPath: linkedSkill.path,
            skillName: "demo"
        ))
        XCTAssertThrowsError(
            try MetagentCore.uninstallStandaloneSkill(
                projectRoot: root.path,
                skillPath: linkedSkill.path,
                skillName: "demo"
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalSkills.appendingPathComponent("demo/SKILL.md").path))
    }

    func testStandaloneRemovalRecoversPerSkillProjection() throws {
        let root = try fixtureRoot("standalone-projection")
        let recoveryHome = try fixtureRoot("standalone-recovery-home")
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", recoveryHome.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: recoveryHome)
        }
        let codexSkills = root.appendingPathComponent(".codex/skills")
        let claudeSkills = root.appendingPathComponent(".claude/skills")
        try writeSkill(named: "demo", under: codexSkills)
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        let canonical = codexSkills.appendingPathComponent("demo")
        let projection = claudeSkills.appendingPathComponent("demo")
        try FileManager.default.createSymbolicLink(at: projection, withDestinationURL: canonical)

        let report = try MetagentCore.uninstallStandaloneSkill(
            projectRoot: root.path,
            skillPath: canonical.path,
            skillName: "demo"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: projection.path))
        XCTAssertTrue(report.lines.contains("removed 1 per-skill projection link(s)"))
        let recovery = URL(fileURLWithPath: try XCTUnwrap(report.backupPath))
            .appendingPathComponent("demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("SKILL.md").path))
    }

    private func fixtureRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-provenance-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSkill(named name: String, under directory: URL) throws {
        let skill = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: fixture\n---\n".write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func scan(_ root: URL) throws -> SkillScanReport {
        try MetagentCore.scanSkills(options: SkillScanOptions(roots: [root.path], maxDepth: 0))
    }
}
