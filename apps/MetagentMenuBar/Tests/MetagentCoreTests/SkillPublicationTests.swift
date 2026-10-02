import Foundation
import XCTest
@testable import MetagentCore

final class SkillPublicationTests: XCTestCase {
    func testSavedPublishingRootCannotReselectExternalCheckout() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "safe-skill")
        _ = try MetagentCore.enableSkillPublicationForTesting(
            sourcePath: source.path, skillName: "safe-skill",
            repositoryPath: fixture.repository.path, storePath: fixture.store
        )
        let external = fixture.root.appendingPathComponent("external-checkout")
        try FileManager.default.createDirectory(at: external.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let externalFile = external.appendingPathComponent("skills/safe-skill/SKILL.md")
        try writeSkillFixture(at: externalFile.deletingLastPathComponent(), name: "safe-skill", body: "External sentinel.")
        let original = try String(contentsOf: externalFile, encoding: .utf8)
        try FileManager.default.moveItem(at: fixture.repository, to: fixture.root.appendingPathComponent("retained-checkout"))
        try FileManager.default.createSymbolicLink(at: fixture.repository, withDestinationURL: external)
        try "Changed source.\n".write(to: source.appendingPathComponent("references/note.md"), atomically: true, encoding: .utf8)

        let report = try MetagentCore.reconcileSkillPublicationsForTesting(storePath: fixture.store)

        XCTAssertEqual(report.blockedRecordIDs.count, 1)
        XCTAssertTrue(report.snapshot.records.first?.findings.contains { $0.id == "linked-repository" } == true)
        XCTAssertEqual(try String(contentsOf: externalFile, encoding: .utf8), original)
    }

    func testInitialPublishingCheckoutAliasRemainsSupported() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "safe-skill")
        let alias = fixture.root.appendingPathComponent("checkout-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.repository)
        let report = try MetagentCore.enableSkillPublicationForTesting(
            sourcePath: source.path, skillName: "safe-skill",
            repositoryPath: alias.path, storePath: fixture.store
        )
        XCTAssertTrue(report.blockedRecordIDs.isEmpty)
        XCTAssertEqual(report.mirroredRecordIDs.count, 1)
        XCTAssertEqual(report.snapshot.catalogs.first?.localRepositoryPath, fixture.repository.resolvingSymlinksInPath().path)
    }

    func testReadinessRejectsNestedLeafAndDanglingDestinationLinks() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "safe-skill")
        let external = fixture.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let nested = fixture.repository.appendingPathComponent("nested")
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: external)
        let skills = fixture.repository.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("safe-skill"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: fixture.repository.appendingPathComponent("dangling"), withDestinationURL: fixture.root.appendingPathComponent("absent"))
        for relativePath in ["nested/skills", "skills", "dangling/skills"] {
            let readiness = MetagentCore.assessSkillPublicationReadinessForTesting(
                sourcePath: source.path, repositoryPath: fixture.repository.path,
                skillsRelativePath: relativePath, destinationName: "safe-skill"
            )
            XCTAssertEqual(readiness.status, .blocked)
            XCTAssertTrue(readiness.findings.contains { $0.id == "linked-destination" })
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    func testMatchedExternalMirrorCannotBypassReadiness() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "safe-skill")
        _ = try MetagentCore.enableSkillPublicationForTesting(
            sourcePath: source.path, skillName: "safe-skill",
            repositoryPath: fixture.repository.path, storePath: fixture.store
        )
        let skillsRoot = fixture.repository.appendingPathComponent("skills")
        let external = fixture.root.appendingPathComponent("matching-external")
        try FileManager.default.moveItem(at: skillsRoot, to: external)
        try FileManager.default.createSymbolicLink(at: skillsRoot, withDestinationURL: external)
        let report = try MetagentCore.reconcileSkillPublicationsForTesting(storePath: fixture.store)
        XCTAssertEqual(report.blockedRecordIDs.count, 1)
        XCTAssertTrue(report.mirroredRecordIDs.isEmpty)
    }

    func testSymlinkedSkillsRootCannotReplaceExternalBundle() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "safe-skill")
        let external = fixture.root.appendingPathComponent("external")
        let externalSkill = external.appendingPathComponent("safe-skill")
        try writeSkillFixture(at: externalSkill, name: "safe-skill", body: "External content must stay intact.")
        let externalFile = externalSkill.appendingPathComponent("SKILL.md")
        let original = try String(contentsOf: externalFile, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.repository.appendingPathComponent("skills"), withDestinationURL: external
        )

        let report = try MetagentCore.enableSkillPublicationForTesting(
            sourcePath: source.path, skillName: "safe-skill",
            repositoryPath: fixture.repository.path, storePath: fixture.store
        )

        XCTAssertEqual(report.blockedRecordIDs.count, 1)
        XCTAssertTrue(report.mirroredRecordIDs.isEmpty)
        XCTAssertEqual(try String(contentsOf: externalFile, encoding: .utf8), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), ["safe-skill"])
    }

    func testReconciliationRefusesSkillsRootReplacedAfterEnable() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "safe-skill")
        _ = try MetagentCore.enableSkillPublicationForTesting(
            sourcePath: source.path, skillName: "safe-skill",
            repositoryPath: fixture.repository.path, storePath: fixture.store
        )
        let skillsRoot = fixture.repository.appendingPathComponent("skills")
        try FileManager.default.moveItem(at: skillsRoot, to: fixture.root.appendingPathComponent("retained-mirror"))
        let external = fixture.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skillsRoot, withDestinationURL: external)
        try "Changed source.\n".write(to: source.appendingPathComponent("references/note.md"), atomically: true, encoding: .utf8)

        let report = try MetagentCore.reconcileSkillPublicationsForTesting(storePath: fixture.store)

        XCTAssertEqual(report.blockedRecordIDs.count, 1)
        XCTAssertTrue(report.mirroredRecordIDs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

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

        let enabled = try MetagentCore.enableSkillPublicationForTesting(
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
        _ = try MetagentCore.reconcileSkillPublicationsForTesting(storePath: fixture.store)
        try FileManager.default.removeItem(at: removed)
        let updated = try MetagentCore.reconcileSkillPublicationsForTesting(
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
        _ = try MetagentCore.enableSkillPublicationForTesting(
            sourcePath: source.path,
            skillName: "source-wins",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )
        let publicSkillFile = fixture.publicSkill(named: "source-wins")
            .appendingPathComponent("SKILL.md")
        try "external edit\n".write(to: publicSkillFile, atomically: true, encoding: .utf8)

        let report = try MetagentCore.reconcileSkillPublicationsForTesting(storePath: fixture.store)

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
        _ = try MetagentCore.enableSkillPublicationForTesting(
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

        let report = try MetagentCore.reconcileSkillPublicationsForTesting(storePath: fixture.store)

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
        _ = try MetagentCore.enableSkillPublicationForTesting(
            sourcePath: source.path,
            skillName: "retained-skill",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )
        let publicSkill = fixture.publicSkill(named: "retained-skill")
        try FileManager.default.removeItem(at: source)

        let report = try MetagentCore.reconcileSkillPublicationsForTesting(storePath: fixture.store)

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

        let readiness = MetagentCore.assessSkillPublicationReadinessForTesting(
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

    func testOccupiedDestinationRejectsNewSourceWithoutDisruptingExistingMirror() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let first = try fixture.skill(named: "first")
        let second = try fixture.skill(named: "second")
        _ = try MetagentCore.enableSkillPublicationForTesting(
            sourcePath: first.path,
            skillName: "first",
            repositoryPath: fixture.repository.path,
            destinationName: "shared",
            storePath: fixture.store
        )
        let before = try Data(contentsOf: fixture.store)
        let readiness = MetagentCore.assessSkillPublicationReadiness(
            sourcePath: second.path, repositoryPath: fixture.repository.path,
            destinationName: "shared", storePath: fixture.store
        )
        XCTAssertEqual(readiness.status, .blocked)
        XCTAssertEqual(readiness.findings.first?.id, "destination-collision")
        XCTAssertThrowsError(try MetagentCore.enableSkillPublicationForTesting(
            sourcePath: second.path,
            skillName: "second",
            repositoryPath: fixture.repository.path,
            destinationName: "shared",
            storePath: fixture.store
        ))
        XCTAssertEqual(try Data(contentsOf: fixture.store), before)
        let snapshot = MetagentCore.loadSkillPublicationSnapshot(path: fixture.store)
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.records.first?.state, .mirrored)
        XCTAssertEqual(try String(contentsOf: fixture.publicSkill(named: "shared").appendingPathComponent("SKILL.md"),
                                  encoding: .utf8),
                       try String(contentsOf: first.appendingPathComponent("SKILL.md"), encoding: .utf8))
        // Resuming the same source remains valid, even through a repository alias.
        XCTAssertNil(snapshot.destinationConflict(sourcePath: first.path,
            repositoryPath: fixture.repository.appendingPathComponent(".").path, destinationName: "shared"))
        let stopped = try MetagentCore.disableSkillPublication(recordID: XCTUnwrap(snapshot.records.first).id,
                                                                storePath: fixture.store)
        XCTAssertNotNil(stopped.destinationConflict(sourcePath: second.path,
            repositoryPath: fixture.repository.path, destinationName: "shared"))
        let renamed = try MetagentCore.enableSkillPublicationForTesting(sourcePath: second.path, skillName: "second",
            repositoryPath: fixture.repository.path, destinationName: "second", storePath: fixture.store)
        XCTAssertEqual(renamed.snapshot.records.last?.state, .mirrored)
    }

    func testExistingCatalogMetadataSurvivesEnablingAnotherSkill() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let first = try fixture.skill(named: "first")
        let second = try fixture.skill(named: "second")
        let initial = try MetagentCore.enableSkillPublicationForTesting(
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

        let updated = try MetagentCore.enableSkillPublicationForTesting(
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

        XCTAssertThrowsError(try MetagentCore.enableSkillPublicationForTesting(
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

        let report = try MetagentCore.enableSkillPublicationForTesting(
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

        let report = try MetagentCore.enableSkillPublicationForTesting(
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

        let report = try MetagentCore.enableSkillPublicationForTesting(
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

    func testPublicAPIRejectsSourcesOutsideCanonicalSkillsFolders() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let original = try fixture.skill(named: "outside-primary")
        let source = fixture.root.appendingPathComponent("outside-primary")
        try FileManager.default.moveItem(at: original, to: source)

        XCTAssertThrowsError(try MetagentCore.enableSkillPublication(
            sourcePath: source.path,
            skillName: "outside-primary",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        ))
    }

    func testPublicReconcileBlocksPersistedOutOfRootRecordAndRetainsCopy() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let original = try fixture.skill(named: "persisted-outside")
        let source = fixture.root.appendingPathComponent("persisted-outside")
        try FileManager.default.moveItem(at: original, to: source)
        _ = try MetagentCore.enableSkillPublicationForTesting(
            sourcePath: source.path,
            skillName: "persisted-outside",
            repositoryPath: fixture.repository.path,
            storePath: fixture.store
        )
        let publicDocument = fixture.publicSkill(named: "persisted-outside")
            .appendingPathComponent("references/note.md")
        try "unsafe new version\n".write(
            to: source.appendingPathComponent("references/note.md"),
            atomically: true,
            encoding: .utf8
        )

        let report = try MetagentCore.reconcileSkillPublications(storePath: fixture.store)

        XCTAssertEqual(report.snapshot.records.first?.state, .updateBlocked)
        XCTAssertTrue(report.snapshot.records.first?.findings.contains {
            $0.id == "source-outside-primary-root"
        } == true)
        XCTAssertEqual(try String(contentsOf: publicDocument, encoding: .utf8), "initial\n")
    }

    func testDisablePersistsWithoutDeletingPublicCopy() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "stop-mirroring")
        let enabled = try MetagentCore.enableSkillPublicationForTesting(
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

    func testSequentialProjectSkillsPublishAndReconcileIndependently() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let first = try fixture.skill(named: "first")
        let second = fixture.root.appendingPathComponent("other-project/.agents/skills/second")
        try writeSkillFixture(at: second, name: "second", body: "Portable second skill.")

        for source in [first, second] {
            XCTAssertTrue(MetagentCore.isSkillPublicationSource(source.path))
            XCTAssertEqual(MetagentCore.assessSkillPublicationReadiness(
                sourcePath: source.path, repositoryPath: fixture.repository.path,
                destinationName: source.lastPathComponent
            ).status, .ready)
            let report = try MetagentCore.enableSkillPublication(
                sourcePath: source.path, skillName: source.lastPathComponent,
                repositoryPath: fixture.repository.path, storePath: fixture.store
            )
            XCTAssertTrue(report.blockedRecordIDs.isEmpty)
        }
        try "updated\n".write(to: first.appendingPathComponent("references/note.md"),
                              atomically: true, encoding: .utf8)
        let reconciled = try MetagentCore.reconcileSkillPublications(storePath: fixture.store)
        XCTAssertEqual(reconciled.snapshot.records.count, 2)
        XCTAssertTrue(reconciled.snapshot.records.allSatisfy { $0.state == .mirrored })
        XCTAssertEqual(try String(contentsOf: fixture.publicSkill(named: "first")
            .appendingPathComponent("references/note.md"), encoding: .utf8), "updated\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.publicSkill(named: "second")
            .appendingPathComponent("SKILL.md").path))
    }

    func testCanonicalSourceCheckRejectsRuntimeCopiesNestedFilesAndEscapingLinks() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "canonical")
        let outside = fixture.root.appendingPathComponent("outside")
        try writeSkillFixture(at: outside, name: "outside", body: "Portable instructions.")
        let link = fixture.sourceRoot.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(MetagentCore.isSkillPublicationSource(link.path))
        XCTAssertFalse(MetagentCore.isSkillPublicationSource(source.appendingPathComponent("references").path))
        XCTAssertFalse(MetagentCore.isSkillPublicationSource(fixture.root.appendingPathComponent(".claude/skills/copy").path))
        XCTAssertTrue(MetagentCore.isSkillPublicationSource(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills/personal").path))
    }

    func testLastSuccessfulRepositoryPersistsAcrossMultipleCatalogsAndBlockedAttempts() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let first = try fixture.skill(named: "first")
        let second = try fixture.skill(named: "second")
        let otherRepository = fixture.root.appendingPathComponent("other-public")
        try FileManager.default.createDirectory(at: otherRepository.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        for (source, repository) in [(first, fixture.repository), (second, otherRepository)] {
            _ = try MetagentCore.enableSkillPublication(sourcePath: source.path,
                skillName: source.lastPathComponent, repositoryPath: repository.path, storePath: fixture.store)
            XCTAssertEqual(MetagentCore.loadSkillPublicationSnapshot(path: fixture.store).preferredRepositoryPath,
                           repository.resolvingSymlinksInPath().path)
        }
        let blocked = try fixture.skill(named: "blocked")
        try "PRIVATE_TOKEN=fixture\n".write(to: blocked.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let report = try MetagentCore.enableSkillPublication(sourcePath: blocked.path,
            skillName: "blocked", repositoryPath: fixture.repository.path, storePath: fixture.store)
        XCTAssertFalse(report.blockedRecordIDs.isEmpty)
        let reloaded = MetagentCore.loadSkillPublicationSnapshot(path: fixture.store)
        XCTAssertEqual(reloaded.catalogs.count, 2)
        XCTAssertEqual(reloaded.preferredRepositoryPath, otherRepository.resolvingSymlinksInPath().path)
    }

    func testLegacyPublicationStoreKeepsItsSingleRepositoryDefault() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.store.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"{"version":1,"catalogs":[{"id":"old","localRepositoryPath":"/old/repo","skillsRelativePath":"skills"}],"records":[{"id":"published","sourceCanonicalPath":"/project/.agents/skills/local","skillName":"local","catalogID":"old","destinationName":"local","automaticMirroringEnabled":true,"state":"mirrored","lastMirroredHash":"previous-hash","findings":[]}]}"#
            .write(to: fixture.store, atomically: true, encoding: .utf8)
        var snapshot = MetagentCore.loadSkillPublicationSnapshot(path: fixture.store)
        XCTAssertNil(snapshot.preferredCatalogID)
        XCTAssertEqual(snapshot.preferredRepositoryPath, "/old/repo")
        snapshot.catalogs.append(SkillPublicationCatalog(id: "failed", localRepositoryPath: "/failed/repo"))
        snapshot.records.append(SkillPublicationRecord(id: "blocked", sourceCanonicalPath: "/project/.agents/skills/blocked",
            skillName: "blocked", catalogID: "failed", destinationName: "blocked", state: .updateBlocked))
        XCTAssertEqual(snapshot.preferredRepositoryPath, "/old/repo")
        try JSONEncoder().encode(snapshot).write(to: fixture.store)
        XCTAssertEqual(MetagentCore.loadSkillPublicationSnapshot(path: fixture.store).preferredRepositoryPath, "/old/repo")
        snapshot.records[1].lastMirroredHash = "another-success"
        XCTAssertNil(snapshot.preferredRepositoryPath, "Multiple legacy successful catalogs remain ambiguous")
    }

    func testFirstBlockedAttemptDoesNotBecomeTheDefaultRepository() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let source = try fixture.skill(named: "blocked")
        try "PRIVATE_TOKEN=fixture\n".write(to: source.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let report = try MetagentCore.enableSkillPublication(sourcePath: source.path,
            skillName: "blocked", repositoryPath: fixture.repository.path, storePath: fixture.store)
        XCTAssertEqual(report.snapshot.records.first?.state, .updateBlocked)
        XCTAssertNil(report.snapshot.preferredRepositoryPath)
        XCTAssertNil(MetagentCore.loadSkillPublicationSnapshot(path: fixture.store).preferredRepositoryPath)
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
