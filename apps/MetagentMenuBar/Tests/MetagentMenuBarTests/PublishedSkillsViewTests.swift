import MetagentCore
import XCTest
@testable import MetagentMenuBar

final class PublishedSkillsViewTests: XCTestCase {
    func testEditableProjectSkillCanPublishButInstalledAndRuntimeCopiesExplainWhyTheyCannot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("publish-menu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(".agents/skills/local")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try """
        ---
        name: local
        description: Portable local instructions
        ---
        Read the project documentation.
        """.write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let scan = try MetagentCore.scanSkills(options: SkillScanOptions(roots: [root.path]))
        var skill = try XCTUnwrap(scan.projects.flatMap(\.skills).first)
        XCTAssertNil(skillPublicationUnavailableReason(skill))
        skill.mutability = "managed-read-only"
        XCTAssertEqual(skillPublicationUnavailableReason(skill), "Publish the editable source, not an installed package.")
        skill.mutability = "editable"
        skill.representation = "projection"
        XCTAssertNotNil(skillPublicationUnavailableReason(skill))
        skill.representation = "canonical"
        skill.manager = "codex-plugin"
        XCTAssertNotNil(skillPublicationUnavailableReason(skill))
    }

    func testConfiguredSkillsDoNotOfferDuplicateSetupButStoppedSkillsCanResume() {
        let active = SkillPublicationRecord(id: "active", sourceCanonicalPath: "/skills/example",
            skillName: "example", catalogID: "catalog", destinationName: "example")
        var stopped = active
        stopped.automaticMirroringEnabled = false
        XCTAssertEqual(activeSkillPublication(for: "/skills/example",
            in: SkillPublicationSnapshot(records: [active]))?.id, "active")
        XCTAssertNil(activeSkillPublication(for: "/skills/other", in: SkillPublicationSnapshot(records: [active])))
        XCTAssertNil(activeSkillPublication(for: "/skills/example", in: SkillPublicationSnapshot(records: [stopped])))
    }

    func testPreviewAndReadinessReuseConfiguredCatalogFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("publication-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogs = [SkillPublicationCatalog(id: "existing", localRepositoryPath: root.path,
            skillsRelativePath: "catalog/skills")]
        XCTAssertEqual(publicationSkillsRelativePath(repositoryPath: root.appendingPathComponent(".").path, catalogs: catalogs),
            "catalog/skills")
        XCTAssertEqual(publicationSkillsRelativePath(repositoryPath: "/tmp/different-repo", catalogs: catalogs), "skills")
    }
}
