import Foundation
import XCTest
@testable import MetagentCore

final class SkillPublicationTests: XCTestCase {
    func testSelectedSkillMirrorsContinuouslyWithoutTouchingOtherRepositoryFiles() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "portable-skill")
        let otherSource = try fixture.skill(named: "private-skill")
        let script = source.appendingPathComponent("scripts/run.sh")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\necho ready\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        try "keep\n".write(
            to: fixture.repository.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let enabled = try MetagentCore.enableSkillPublication(
            sourcePath: source.path,
            skillName: "portable-skill",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store,
            now: fixture.dayOne
        )

        XCTAssertEqual(enabled.snapshot.records.count, 1)
        XCTAssertEqual(enabled.mirroredRecordIDs.count, 1)
        let publicSkill = fixture.publicSkill(named: "portable-skill")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: publicSkill.appendingPathComponent("SKILL.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.publicSkill(named: otherSource.lastPathComponent).path
        ))
        XCTAssertEqual(
            try String(
                contentsOf: fixture.repository.appendingPathComponent("README.md"),
                encoding: .utf8
            ),
            "keep\n"
        )
        let permissions = try FileManager.default.attributesOfItem(
            atPath: publicSkill.appendingPathComponent("scripts/run.sh").path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)

        try "updated\n".write(
            to: source.appendingPathComponent("references/note.md"),
            atomically: true,
            encoding: .utf8
        )
        let removed = source.appendingPathComponent("obsolete.txt")
        try "old\n".write(to: removed, atomically: true, encoding: .utf8)
        _ = try MetagentCore.reconcileSkillPublications(storePath: fixture.store)
        try FileManager.default.removeItem(at: removed)
        let updated = try MetagentCore.reconcileSkillPublications(
            storePath: fixture.store,
            now: fixture.dayTwo
        )

        XCTAssertEqual(updated.mirroredRecordIDs.count, 1)
        XCTAssertEqual(
            try String(
                contentsOf: publicSkill.appendingPathComponent("references/note.md"),
                encoding: .utf8
            ),
            "updated\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: publicSkill.appendingPathComponent("obsolete.txt").path
        ))
    }

    func testCanonicalSourceOverwritesExternalDestinationEdits() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "source-wins")
        _ = try MetagentCore.enableSkillPublication(
            sourcePath: source.path,
            skillName: "source-wins",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )
        let publicSkillFile = fixture.publicSkill(named: "source-wins")
            .appendingPathComponent("SKILL.md")
        try "external edit\n".write(to: publicSkillFile, atomically: true, encoding: .utf8)

        let report = try MetagentCore.reconcileSkillPublications(storePath: fixture.store)

        XCTAssertEqual(report.mirroredRecordIDs.count, 1)
        XCTAssertEqual(
            try String(contentsOf: publicSkillFile, encoding: .utf8),
            try String(
                contentsOf: source.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            )
        )
    }

    func testBlockedUpdateRetainsLastSafePublicCopy() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "safe-skill")
        _ = try MetagentCore.enableSkillPublication(
            sourcePath: source.path,
            skillName: "safe-skill",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )
        let publicSkillFile = fixture.publicSkill(named: "safe-skill")
            .appendingPathComponent("SKILL.md")
        let safeText = try String(contentsOf: publicSkillFile, encoding: .utf8)
        try (safeText + "\nRead /Users/private-user/secrets.json\n").write(
            to: source.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let report = try MetagentCore.reconcileSkillPublications(storePath: fixture.store)

        XCTAssertEqual(report.blockedRecordIDs.count, 1)
        XCTAssertEqual(report.snapshot.records.first?.state, .updateBlocked)
        XCTAssertTrue(report.snapshot.records.first?.findings.contains {
            $0.id.hasPrefix("personal-path:")
        } == true)
        XCTAssertEqual(try String(contentsOf: publicSkillFile, encoding: .utf8), safeText)
    }

    func testMissingSourceRetainsPublicCopy() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "retained-skill")
        _ = try MetagentCore.enableSkillPublication(
            sourcePath: source.path,
            skillName: "retained-skill",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )
        let publicSkill = fixture.publicSkill(named: "retained-skill")
        try FileManager.default.removeItem(at: source)

        let report = try MetagentCore.reconcileSkillPublications(storePath: fixture.store)

        XCTAssertEqual(report.snapshot.records.first?.state, .sourceMissing)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: publicSkill.appendingPathComponent("SKILL.md").path
        ))
    }

    func testSymlinkSecretAndMissingScriptBlockPublication() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "blocked-skill", body: "Run `scripts/missing.sh`.")
        try "github_pat_abcdefghijklmnopqrstuvwxyz123456\n".write(
            to: source.appendingPathComponent("credentials.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("linked.txt").path,
            withDestinationPath: "credentials.txt"
        )

        let readiness = MetagentCore.assessSkillPublicationReadiness(
            sourcePath: source.path,
            repositoryPath: fixture.repository.path,
            destinationName: "blocked-skill"
        )

        XCTAssertEqual(readiness.status, .blocked)
        XCTAssertTrue(readiness.findings.contains { $0.id.hasPrefix("secret-literal:") })
        XCTAssertTrue(readiness.findings.contains { $0.id.hasPrefix("symlink:") })
        XCTAssertTrue(readiness.findings.contains { $0.id == "missing-script:scripts/missing.sh" })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.publicSkill(named: "blocked-skill").path
        ))
    }

    func testDestinationCollisionBlocksBothRecords() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let first = try fixture.skill(named: "first")
        let second = try fixture.skill(named: "second")
        _ = try MetagentCore.enableSkillPublication(
            sourcePath: first.path,
            skillName: "first",
            repositoryPath: fixture.repository.path,
            destinationName: "shared",
            storePath: fixture.store
        )
        let report = try MetagentCore.enableSkillPublication(
            sourcePath: second.path,
            skillName: "second",
            repositoryPath: fixture.repository.path,
            destinationName: "shared",
            storePath: fixture.store
        )

        XCTAssertEqual(report.blockedRecordIDs.count, 2)
        XCTAssertTrue(report.snapshot.records.allSatisfy { $0.state == .updateBlocked })
    }

    func testExistingCatalogMetadataSurvivesEnablingAnotherSkill() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let first = try fixture.skill(named: "first")
        let second = try fixture.skill(named: "second")
        let initial = try MetagentCore.enableSkillPublication(
            sourcePath: first.path,
            skillName: "first",
            repositoryPath: fixture.repository.path,
            remoteURL: "https://github.com/example/public-skills.git",
            storePath: fixture.store
        )
        let original = try XCTUnwrap(initial.snapshot.catalogs.first)
        let customized = SkillPublicationSnapshot(
            catalogs: [SkillPublicationCatalog(
                id: original.id,
                localRepositoryPath: original.localRepositoryPath,
                skillsRelativePath: "agent-skills",
                remoteURL: original.remoteURL
            )],
            records: initial.snapshot.records
        )
        try MetagentCore.saveSkillPublicationSnapshot(customized, path: fixture.store)

        let updated = try MetagentCore.enableSkillPublication(
            sourcePath: second.path,
            skillName: "second",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )

        XCTAssertEqual(updated.snapshot.catalogs.first?.skillsRelativePath, "agent-skills")
        XCTAssertEqual(
            updated.snapshot.catalogs.first?.remoteURL,
            "https://github.com/example/public-skills.git"
        )
    }

    func testUnreadableStoreBlocksMutationAndPreservesRecoveryCopy() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "safe-skill")
        try FileManager.default.createDirectory(
            at: fixture.store.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: fixture.store)

        XCTAssertThrowsError(try MetagentCore.enableSkillPublication(
            sourcePath: source.path,
            skillName: "safe-skill",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        ))

        XCTAssertEqual(try Data(contentsOf: fixture.store), corrupt)
        XCTAssertEqual(
            try Data(contentsOf: fixture.store.appendingPathExtension("unreadable")),
            corrupt
        )
    }

    func testLargeTextFileStillReceivesCredentialScan() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "large-text")
        let credential = "api_key = \"sk-test-secret-value-1234567890\"\n"
        let body = credential + String(repeating: "x", count: 1_100_000)
        try body.write(
            to: source.appendingPathComponent("reference.txt"),
            atomically: true,
            encoding: .utf8
        )

        let report = try MetagentCore.enableSkillPublication(
            sourcePath: source.path,
            skillName: "large-text",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )

        XCTAssertEqual(report.snapshot.records.first?.state, .updateBlocked)
        XCTAssertTrue(report.snapshot.records.first?.findings.contains {
            $0.id == "secret-literal:reference.txt"
        } == true)
    }

    func testEnvironmentVariantAndEmptyFrontmatterBlockPublication() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "unsafe-metadata")
        try "---\nname:\ndescription: \"\"\n---\nInstructions.\n".write(
            to: source.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try "STRIPE_SECRET_KEY=sk_live_not-for-publication\n".write(
            to: source.appendingPathComponent(".env.production"),
            atomically: true,
            encoding: .utf8
        )

        let report = try MetagentCore.enableSkillPublication(
            sourcePath: source.path,
            skillName: "unsafe-metadata",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )

        let findingIDs = Set(report.snapshot.records.first?.findings.map(\.id) ?? [])
        XCTAssertEqual(report.snapshot.records.first?.state, .updateBlocked)
        XCTAssertTrue(findingIDs.contains("invalid-frontmatter"))
        XCTAssertTrue(findingIDs.contains("secret-file:.env.production"))
    }

    func testInvalidUTF8SkillDocumentBlocksPublication() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "invalid-utf8")
        try Data([0xff, 0xfe, 0x00]).write(to: source.appendingPathComponent("SKILL.md"))

        let report = try MetagentCore.enableSkillPublication(
            sourcePath: source.path,
            skillName: "invalid-utf8",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )

        XCTAssertEqual(report.snapshot.records.first?.state, .updateBlocked)
        XCTAssertTrue(report.snapshot.records.first?.findings.contains {
            $0.id == "invalid-skill-encoding"
        } == true)
    }

    func testDisablePersistsWithoutDeletingPublicCopy() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "stop-mirroring")
        let enabled = try MetagentCore.enableSkillPublication(
            sourcePath: source.path,
            skillName: "stop-mirroring",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )
        let recordID = try XCTUnwrap(enabled.snapshot.records.first?.id)

        let disabled = try MetagentCore.disableSkillPublication(
            recordID: recordID,
            storePath: fixture.store
        )
        let reloaded = MetagentCore.loadSkillPublicationSnapshot(path: fixture.store)

        XCTAssertEqual(disabled.records.first?.state, .disabled)
        XCTAssertEqual(reloaded, disabled)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.publicSkill(named: "stop-mirroring")
                .appendingPathComponent("SKILL.md").path
        ))
    }
}

private struct PublicationFixture {
    let root: URL
    let sourceRoot: URL
    let repository: URL
    let store: URL
    let dayOne = Date(timeIntervalSince1970: 1_750_000_000)
    let dayTwo = Date(timeIntervalSince1970: 1_750_086_400)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-publication-\(UUID().uuidString)")
        sourceRoot = root.appendingPathComponent("private/.agents/skills")
        repository = root.appendingPathComponent("public-skills")
        store = root.appendingPathComponent("state/skill-publications-v1.json")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
    }

    func skill(named name: String, body: String = "Portable instructions.") throws -> URL {
        let directory = sourceRoot.appendingPathComponent(name)
        try writeSkillFixture(at: directory, name: name, body: body)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("references"),
            withIntermediateDirectories: true
        )
        try "initial\n".write(
            to: directory.appendingPathComponent("references/note.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    func publicSkill(named name: String) -> URL {
        repository.appendingPathComponent("skills/\(name)")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
