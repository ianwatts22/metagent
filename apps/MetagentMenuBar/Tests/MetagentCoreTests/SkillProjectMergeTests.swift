import XCTest
@testable import MetagentCore

final class SkillProjectMergeTests: XCTestCase {
    func testMergeRetainsFolderMetadataAndLaterMatchingRowsWin() {
        let root = "/tmp/project"
        let first = SkillInventoryItem.fixture(name: "zulu", path: root + "/zulu")
        var replacement = first
        replacement.description = "new scan"
        let second = SkillInventoryItem.fixture(name: "Alpha", path: root + "/alpha")
        let original = SkillProject(
            root: root, skillsDir: root + "/custom",
            validSkills: ["zulu"], skills: [first],
            invalidSkillDirs: ["broken"], hiddenSkillDirs: [".hidden"]
        )
        let additional = SkillProject(
            root: root, skillsDir: root + "/other",
            validSkills: ["zulu", "alpha"], skills: [replacement, second],
            invalidSkillDirs: ["broken", "another"], hiddenSkillDirs: [".hidden", ".another"]
        )

        let merged = original.merging(with: additional)
        XCTAssertEqual(merged.root, root)
        XCTAssertEqual(merged.skillsDir, original.skillsDir)
        XCTAssertEqual(merged.validSkills, ["alpha", "zulu"])
        XCTAssertEqual(merged.invalidSkillDirs, ["another", "broken"])
        XCTAssertEqual(merged.hiddenSkillDirs, [".another", ".hidden"])
        XCTAssertEqual(merged.skills, [second, replacement])
        XCTAssertEqual(merged.skills.map(\.id), [second.id, first.id])
        XCTAssertEqual(merged.merging(with: additional), merged)
    }
}
