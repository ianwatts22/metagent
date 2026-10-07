import Foundation
import XCTest
@testable import MetagentCore

final class SkillsCLIUpdateTests: XCTestCase {
    func testReminderIsDueWhenNeverRunOrOlderThanTwoDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SkillsCLIUpdatePolicy.isDue(lastRun: nil, now: now))
        XCTAssertFalse(SkillsCLIUpdatePolicy.isDue(lastRun: now.addingTimeInterval(-47 * 60 * 60), now: now))
        XCTAssertTrue(SkillsCLIUpdatePolicy.isDue(lastRun: now.addingTimeInterval(-48 * 60 * 60), now: now))
    }

    func testArgumentsScopeEachRunAndSkipPrompts() {
        XCTAssertEqual(MetagentCore.skillsCLIUpdateArguments(isGlobal: true), ["--yes", "skills", "update", "--global", "--yes"])
        XCTAssertEqual(MetagentCore.skillsCLIUpdateArguments(isGlobal: false), ["--yes", "skills", "update", "--project", "--yes"])
    }

    func testSummaryPrefersResultLinesAndStripsANSI() {
        let upToDate = skillsCLIPlainOutput("\u{1B}[38;5;145mChecking for skill updates…\u{1B}[0m\n\n\u{1B}[38;5;145m✓ All global skills are up to date\u{1B}[0m\n")
        XCTAssertEqual(skillsCLIUpdateSummary(upToDate), "All global skills are up to date")
        let mixed = "Checking 3 skill(s)…\nUpdated alpha\nUpdated 2 skill(s)\nFailed to update 1 skill(s)\n"
        XCTAssertEqual(skillsCLIUpdateSummary(mixed), "Updated 2 skill(s); Failed to update 1 skill(s)")
        XCTAssertEqual(skillsCLIUpdateSummary("something odd\n"), "something odd")
        XCTAssertNil(skillsCLIUpdateSummary("\n  \n"))
    }

    func testTargetsOnlyIncludeProjectsWithSkillsLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metagent-skills-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locked = root.appendingPathComponent("locked")
        let plain = root.appendingPathComponent("plain")
        for path in [locked, plain] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data(#"{"version":1,"skills":{}}"#.utf8).write(to: locked.appendingPathComponent("skills-lock.json"))
        let targets = MetagentCore.skillsCLIUpdateTargets(projectRoots: [plain.path, locked.path, locked.path])
        XCTAssertEqual(targets.projects, [locked.standardizedFileURL.path])
    }
}
