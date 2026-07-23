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

    func testKnownExternalCLIBundleUsesSpecificManagerEvidence() throws {
        let root = try fixtureRoot("external-cli")
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".agents/skills/impeccable")
        try FileManager.default.createDirectory(
            at: skill.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: skill.appendingPathComponent("reference"),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: impeccable
        description: External design workflow.
        version: 3.9.1
        ---

        Run `node .agents/skills/impeccable/scripts/context.mjs`.
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "".write(to: skill.appendingPathComponent("scripts/context.mjs"), atomically: true, encoding: .utf8)
        try "".write(to: skill.appendingPathComponent("reference/hooks.md"), atomically: true, encoding: .utf8)

        let inventoried = try XCTUnwrap(try scan(root).projects.first?.skills.first)

        XCTAssertEqual(inventoried.manager, "external-cli")
        XCTAssertEqual(inventoried.authority, "Impeccable CLI")
        XCTAssertEqual(inventoried.source, "pbakaus/impeccable")
        XCTAssertEqual(inventoried.sourceURL, "https://github.com/pbakaus/impeccable")
        XCTAssertEqual(inventoried.ref, "3.9.1")
        XCTAssertEqual(inventoried.mutability, "managed-read-only")
    }

    func testUpdateSkillIconWritesPortableAssetAndPreservesMetadata() throws {
        let root = try fixtureRoot("icon")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let agents = skill.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try """
        interface:
          display_name: Demo
        policy:
          allow_implicit_invocation: true
          icon_small: keep-policy-icon.png
        """.write(to: agents.appendingPathComponent("openai.yaml"), atomically: true, encoding: .utf8)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))

        let report = try MetagentCore.updateSkillIcon(skillPath: skill.path, pngData: png)
        let metadata = try String(contentsOfFile: report.metadataPath, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: report.iconPath))
        XCTAssertTrue(metadata.contains("display_name: Demo"))
        XCTAssertTrue(metadata.contains("allow_implicit_invocation: true"))
        XCTAssertTrue(metadata.contains("icon_small: keep-policy-icon.png"))
        XCTAssertTrue(metadata.contains("icon_small: assets/metagent-icon.png"))
        XCTAssertTrue(metadata.contains("icon_large: assets/metagent-icon.png"))
        let inventoried = try XCTUnwrap(try scan(root).projects.first?.skills.first)
        XCTAssertEqual(inventoried.iconSmallPath, report.iconPath)
        XCTAssertEqual(inventoried.iconLargePath, report.iconPath)
    }

    func testUpdateSkillIconRejectsMalformedPNG() throws {
        let root = try fixtureRoot("invalid-icon")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let malformed = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00])

        XCTAssertThrowsError(try MetagentCore.updateSkillIcon(skillPath: skill.path, pngData: malformed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.appendingPathComponent("assets/metagent-icon.png").path))
    }

    func testUpdateSkillIconRejectsSymlinkedDestination() throws {
        let root = try fixtureRoot("symlinked-icon")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let external = root.appendingPathComponent("external-assets")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: skill.appendingPathComponent("assets"),
            withDestinationURL: external
        )
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))

        XCTAssertThrowsError(try MetagentCore.updateSkillIcon(skillPath: skill.path, pngData: png))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("metagent-icon.png").path))
    }

    func testDotagentsAdoptedLocalPathDoesNotClaimOwnership() throws {
        let root = try fixtureRoot("dotagents")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))
        try """
        version = 1

        [[skills]] # adopted declaration
        name = "demo" # local display name
        source = "path:.agents/skills/demo" # canonical source
        """.write(to: root.appendingPathComponent("agents.toml"), atomically: true, encoding: .utf8)
        try """
        version = 1

        [skills.demo] # adopted lock entry
        source = "path:.agents/skills/demo"
        """.write(to: root.appendingPathComponent("agents.lock"), atomically: true, encoding: .utf8)

        let skill = try XCTUnwrap(try scan(root).projects.first?.skills.first { $0.location == "agents" })

        XCTAssertEqual(skill.manager, "local")
        XCTAssertEqual(skill.authority, "unknown")
        XCTAssertEqual(skill.originKind, "project-local")
        XCTAssertEqual(skill.mutability, "editable")
        XCTAssertEqual(skill.sourceType, "local")
        let removal = try MetagentCore.planSkillRemoval(projectRoot: root.path, skillName: "demo")
        XCTAssertTrue(removal.applySupported)
        XCTAssertEqual(removal.manager, "local")
        XCTAssertNil(removal.command)
    }

    func testDotagentsDistinctPathSourceIsManagerEvidence() throws {
        let root = try fixtureRoot("dotagents-external")
        let shared = root.appendingPathComponent("shared/demo")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(named: "demo", under: root.appendingPathComponent(".agents/skills"))
        try writeSkill(named: "demo", under: root.appendingPathComponent("shared"))
        try """
        version = 1

        [[skills]]
        name = "demo"
        source = "path:shared/demo"
        """.write(to: root.appendingPathComponent("agents.toml"), atomically: true, encoding: .utf8)

        let skill = try XCTUnwrap(try scan(root).projects.first?.skills.first { $0.location == "agents" })

        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("SKILL.md").path))
        XCTAssertEqual(skill.manager, "dotagents")
        XCTAssertEqual(skill.originKind, "dotagents-local")
        XCTAssertEqual(skill.source, "path:shared/demo")
    }

    func testDotagentsDistinctSymlinkSourceIsManagerEvidence() throws {
        let root = try fixtureRoot("dotagents-external-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedDirectory = root.appendingPathComponent("shared")
        try writeSkill(named: "demo", under: sharedDirectory)
        let installedDirectory = root.appendingPathComponent(".agents/skills")
        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: installedDirectory.appendingPathComponent("demo"),
            withDestinationURL: sharedDirectory.appendingPathComponent("demo")
        )
        try """
        version = 1

        [[skills]]
        name = "demo"
        source = "path:shared/demo"
        """.write(to: root.appendingPathComponent("agents.toml"), atomically: true, encoding: .utf8)

        let skill = try XCTUnwrap(try scan(root).projects.first?.skills.first { $0.location == "agents" })

        XCTAssertEqual(skill.manager, "dotagents")
        XCTAssertEqual(skill.originKind, "dotagents-local")
        XCTAssertEqual(skill.source, "path:shared/demo")
    }

    func testGitTrackingDoesNotInventUpstreamOwnership() throws {
        let repository = try fixtureRoot("repository")
        let local = try fixtureRoot("local")
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: local)
        }
        try writeSkill(named: "repo-skill", under: repository.appendingPathComponent(".agents/skills"))
        try runGit(["init"], at: repository)
        try runGit(["add", ".agents/skills/repo-skill/SKILL.md"], at: repository)
        try writeSkill(named: "local-skill", under: local.appendingPathComponent(".agents/skills"))
        try writeSkill(named: "untracked-skill", under: repository.appendingPathComponent(".agents/skills"))

        let repositorySkills = try XCTUnwrap(try scan(repository).projects.first).skills
        let repositorySkill = try XCTUnwrap(repositorySkills.first { $0.name == "repo-skill" })
        let untrackedSkill = try XCTUnwrap(repositorySkills.first { $0.name == "untracked-skill" })
        let localSkill = try XCTUnwrap(try scan(local).projects.first?.skills.first)

        XCTAssertEqual(repositorySkill.manager, "local")
        XCTAssertEqual(repositorySkill.authority, "unknown")
        XCTAssertEqual(repositorySkill.originKind, "project-local")
        XCTAssertNil(repositorySkill.source)
        XCTAssertNil(repositorySkill.sourceURL)
        XCTAssertEqual(untrackedSkill.manager, "local")
        XCTAssertEqual(untrackedSkill.originKind, "project-local")
        XCTAssertEqual(localSkill.manager, "local")
        XCTAssertEqual(localSkill.authority, "unknown")
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
        let recoveryRoot = URL(fileURLWithPath: try XCTUnwrap(report.backupPath))
        let recovery = recoveryRoot.appendingPathComponent("demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryRoot.appendingPathComponent("before.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryRoot.appendingPathComponent("after.json").path))
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

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
