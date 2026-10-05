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
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let helper = packageRoot.appendingPathComponent(".build/debug/metagent")
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
}
