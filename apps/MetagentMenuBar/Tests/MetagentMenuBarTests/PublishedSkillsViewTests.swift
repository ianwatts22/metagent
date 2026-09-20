import MetagentCore
import XCTest
@testable import MetagentMenuBar

final class PublishedSkillsViewTests: XCTestCase {
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
