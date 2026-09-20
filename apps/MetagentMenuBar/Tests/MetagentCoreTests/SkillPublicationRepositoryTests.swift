import Foundation
import XCTest
@testable import MetagentCore

final class SkillPublicationRepositoryTests: XCTestCase {
    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("publication-home-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    func testCreatesLocalRepositoryAndReusesWithoutStaging() throws {
        try withHome { home in
            let first = MetagentCore.prepareSkillPublicationRepository(home: home)
            XCTAssertEqual(first.outcome, .created, first.message)
            let root = URL(fileURLWithPath: first.path)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".git/HEAD"), encoding: .utf8), "ref: refs/heads/main\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/refs/heads/main").path))
            let file = root.appendingPathComponent("keep.txt")
            try "unchanged".write(to: file, atomically: true, encoding: .utf8)
            let reused = MetagentCore.prepareSkillPublicationRepository(home: home)
            XCTAssertEqual(reused.outcome, .reused, reused.message)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unchanged")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index").path))
            XCTAssertFalse(try String(contentsOf: root.appendingPathComponent(".git/config"), encoding: .utf8).contains("remote"))
        }
    }

    func testInitializesEmptyExistingFolder() throws {
        try withHome { home in
            try FileManager.default.createDirectory(at: home.appendingPathComponent("public-agent-setup"), withIntermediateDirectories: false)
            XCTAssertEqual(MetagentCore.prepareSkillPublicationRepository(home: home).outcome, .created)
        }
    }

    func testNewRepositorySupportsSelectedSkillMirroring() throws {
        try withHome { home in
            let setup = MetagentCore.prepareSkillPublicationRepository(home: home)
            let source = home.appendingPathComponent("private-skills/example")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "---\nname: example\ndescription: A portable example skill.\n---\n\nHelp with examples.\n".write(
                to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let report = try MetagentCore.enableSkillPublicationForTesting(
                sourcePath: source.path, skillName: "example", repositoryPath: setup.path,
                storePath: home.appendingPathComponent("publications.json"))
            XCTAssertEqual(report.mirroredRecordIDs.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: setup.path + "/skills/example/SKILL.md"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: setup.path + "/.git/index"))
        }
    }

    func testRefusesOccupiedNonRepository() throws {
        try withHome { home in
            let root = home.appendingPathComponent("public-agent-setup")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try "private".write(to: root.appendingPathComponent("private.txt"), atomically: true, encoding: .utf8)
            XCTAssertEqual(MetagentCore.prepareSkillPublicationRepository(home: home).outcome, .blocked)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["private.txt"])
        }
    }

    func testRefusesFileAndDanglingSymlink() throws {
        try withHome { home in
            let root = home.appendingPathComponent("public-agent-setup")
            try "keep".write(to: root, atomically: true, encoding: .utf8)
            XCTAssertEqual(MetagentCore.prepareSkillPublicationRepository(home: home).outcome, .blocked)
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: home.appendingPathComponent("missing"))
            XCTAssertEqual(MetagentCore.prepareSkillPublicationRepository(home: home).outcome, .blocked)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("missing").path))
        }
    }

    func testRefusesSymlinkToExistingFolder() throws {
        try withHome { home in
            let target = home.appendingPathComponent("private")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("public-agent-setup"), withDestinationURL: target)
            XCTAssertEqual(MetagentCore.prepareSkillPublicationRepository(home: home).outcome, .blocked)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }
}
