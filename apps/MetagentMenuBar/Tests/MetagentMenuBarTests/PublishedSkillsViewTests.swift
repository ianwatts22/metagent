import MetagentCore
import XCTest
@testable import MetagentMenuBar

final class PublishedSkillsViewTests: XCTestCase {
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
