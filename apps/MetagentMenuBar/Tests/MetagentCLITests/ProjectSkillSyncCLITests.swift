import Foundation
import XCTest
@testable import MetagentCore

final class ProjectSkillSyncCLITests: XCTestCase {
    func testBlockedApplyEmitsDetailedPreviewAndFailsWithoutCopying() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-sync-cli-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let syntheticHome = fixture.appendingPathComponent("synthetic-home")
        let source = syntheticHome.appendingPathComponent(".agents/skills/demo")
        let project = fixture.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Synthetic CLI regression fixture.\n---\n".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"))
        try Data("SYNTHETIC_FIXTURE_ONLY=yes\n".utf8).write(to: source.appendingPathComponent(".env"))
        let helper = Bundle(for: ProjectSkillSyncCLITests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("metagent")
        _ = try XCTUnwrap(FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil,
                      "SwiftPM must build the helper beside the active test bundle.")
        for format in [[], ["--json"]] {
            let result = try runSubprocess(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [
                "-i", "PATH=/usr/bin:/bin", "HOME=\(syntheticHome.path)", helper.path,
                "skills", "sync-to-project", "demo", "--root", project.path, "--apply",
            ] + format, timeout: 10)
            XCTAssertFalse(result.timedOut)
            XCTAssertEqual(result.status, 1)
            if format.isEmpty {
                XCTAssertTrue(String(decoding: result.standardOutput, as: UTF8.self).contains("demo: blocked"))
            } else {
                let report = try XCTUnwrap(JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any])
                XCTAssertEqual(report["applied"] as? Bool, false)
                XCTAssertNil(report["error"])
                let plan = try XCTUnwrap(report["plan"] as? [String: Any])
                let items = try XCTUnwrap(plan["items"] as? [[String: Any]])
                XCTAssertEqual(items.first?["name"] as? String, "demo")
                XCTAssertEqual(items.first?["action"] as? String, "blocked")
                XCTAssertFalse(try XCTUnwrap(items.first?["findings"] as? [[String: Any]]).isEmpty)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".agents").path))
        }
    }

    func testFollowPreviewsThenAppliesGlobalChangesToRecordedSkills() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-follow-cli-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let syntheticHome = fixture.appendingPathComponent("synthetic-home")
        let source = syntheticHome.appendingPathComponent(".agents/skills/demo")
        let project = fixture.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("---\nname: demo\ndescription: Synthetic follow fixture.\n---\n".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"))
        let helper = Bundle(for: ProjectSkillSyncCLITests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("metagent")
        func run(_ arguments: [String]) throws -> (status: Int32, json: [String: Any]) {
            let result = try runSubprocess(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [
                "-i", "PATH=/usr/bin:/bin", "HOME=\(syntheticHome.path)", helper.path,
                "skills", "sync-to-project",
            ] + arguments + ["--root", project.path, "--json"], timeout: 10)
            XCTAssertFalse(result.timedOut)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any])
            return (result.status, json)
        }
        XCTAssertEqual(try run(["demo", "--apply"]).status, 0)
        try Data("Global update.".utf8).write(to: source.appendingPathComponent("global.md"))
        let copied = project.appendingPathComponent(".agents/skills/demo/global.md")

        let preview = try run(["--follow"])
        XCTAssertEqual(preview.status, 0)
        XCTAssertEqual(preview.json["applied"] as? Bool, false)
        let projects = try XCTUnwrap(preview.json["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.first?["updated_names"] as? [String], ["demo"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))

        let applied = try run(["--follow", "--apply"])
        XCTAssertEqual(applied.status, 0)
        XCTAssertEqual(applied.json["applied"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))

        try FileManager.default.removeItem(at: source)
        let removed = try run(["--follow", "--apply"])
        XCTAssertEqual(removed.status, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }
}
