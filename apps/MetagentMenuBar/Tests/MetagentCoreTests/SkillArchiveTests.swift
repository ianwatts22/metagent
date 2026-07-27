import Foundation
import XCTest
@testable import MetagentCore

final class SkillArchiveTests: XCTestCase {
    private var originalHome: String?

    override func setUpWithError() throws {
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        let home = try makeTemporaryRoot(prefix: "metagent-archive-home")
        setenv("HOME", home.path, 1)
    }

    override func tearDown() {
        restoreEnvironment("HOME", originalHome)
        super.tearDown()
    }

    func testDryRunPlansWithoutMutating() throws {
        let root = try canonicalFixture("dry-run")
        let skill = root.appendingPathComponent(".agents/skills/demo")
        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))

        let report = MetagentCore.archiveSkills(targets: [target])

        XCTAssertFalse(report.apply)
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.lines.contains { $0.hasPrefix("would archive demo to ") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(MetagentCore.listArchivedSkills().isEmpty)
    }

    func testArchivesCanonicalSkillWithProjections() throws {
        let root = try canonicalFixture("apply")
        let resolvedRoot = root.resolvingSymlinksInPath()
        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))

        let report = MetagentCore.archiveSkills(targets: [target], apply: true)

        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        let entryDir = URL(fileURLWithPath: try XCTUnwrap(outcome.archivePath))

        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(
            atPath: root.appendingPathComponent(".agents/skills/demo").path
        ))
        XCTAssertNil(try? fileManager.attributesOfItem(
            atPath: root.appendingPathComponent(".claude/skills/demo").path
        ))
        XCTAssertTrue(fileManager.fileExists(
            atPath: entryDir.appendingPathComponent("demo/SKILL.md").path
        ))
        XCTAssertNotNil(try? fileManager.attributesOfItem(
            atPath: entryDir.appendingPathComponent("projections/0-claude/demo").path
        ))

        let archived = MetagentCore.listArchivedSkills()
        XCTAssertEqual(archived.map(\.skillName), ["demo"])
        let entry = try XCTUnwrap(archived.first)
        XCTAssertEqual(entry.method, "canonical")
        XCTAssertEqual(entry.projectRoot, resolvedRoot.path)
        XCTAssertEqual(entry.skillPath, resolvedRoot.appendingPathComponent(".agents/skills/demo").path)
        XCTAssertEqual(entry.projections.count, 1)
        XCTAssertEqual(entry.projections.first?.location, "claude")
        XCTAssertEqual(entry.archivePath, entryDir.path)
    }

    func testRefusesSecondArchiveOfSameName() throws {
        let firstRoot = try canonicalFixture("dup-first")
        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: firstRoot.path,
            skillName: "demo"
        ))
        XCTAssertTrue(MetagentCore.archiveSkills(targets: [target], apply: true)
            .outcomes.allSatisfy(\.succeeded))

        let secondRoot = try canonicalFixture("dup-second")
        let second = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: secondRoot.path,
            skillName: "demo"
        ))
        let report = MetagentCore.archiveSkills(targets: [second], apply: true)

        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(try XCTUnwrap(outcome.failureMessage).contains("already archived"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: secondRoot.appendingPathComponent(".agents/skills/demo/SKILL.md").path
        ))
    }

    func testRefusesManagedSkill() throws {
        let root = try canonicalFixture("managed")
        let lock = """
        {"skills": {"demo": {"source": "github:example/skills", "skillPath": "demo"}}}
        """
        try lock.write(
            to: root.appendingPathComponent("skills-lock.json"),
            atomically: true,
            encoding: .utf8
        )
        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))

        let report = MetagentCore.archiveSkills(targets: [target], apply: true)

        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(try XCTUnwrap(outcome.failureMessage).contains("managed by"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".agents/skills/demo/SKILL.md").path
        ))
    }

    func testRefusesCodexPlugin() throws {
        let report = MetagentCore.archiveSkills(
            targets: [.codexPlugin(pluginID: "openai/tools@marketplace")],
            apply: true
        )
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(try XCTUnwrap(outcome.failureMessage).contains("Codex plugin"))
    }

    func testArchiveRestoreRoundTrip() throws {
        let root = try canonicalFixture("round-trip")
        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))
        let archiveReport = MetagentCore.archiveSkills(targets: [target], apply: true)
        XCTAssertTrue(archiveReport.outcomes.allSatisfy(\.succeeded))

        let restore = try MetagentCore.restoreArchivedSkill(named: "demo")

        let fileManager = FileManager.default
        XCTAssertEqual(
            restore.restoredPath,
            root.resolvingSymlinksInPath().appendingPathComponent(".agents/skills/demo").path
        )
        XCTAssertTrue(fileManager.fileExists(
            atPath: root.appendingPathComponent(".agents/skills/demo/SKILL.md").path
        ))
        // The projection link is back and resolves through to the bundle.
        XCTAssertTrue(fileManager.fileExists(
            atPath: root.appendingPathComponent(".claude/skills/demo/SKILL.md").path
        ))
        XCTAssertTrue(restore.lines.contains("restored 1 per-skill projection link(s)"))
        XCTAssertTrue(MetagentCore.listArchivedSkills().isEmpty)
        XCTAssertFalse(fileManager.fileExists(
            atPath: MetagentCore.archivedSkillsRoot().appendingPathComponent("demo").path
        ))
    }

    func testRestoreRefusesOccupiedDestination() throws {
        let root = try canonicalFixture("occupied")
        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))
        XCTAssertTrue(MetagentCore.archiveSkills(targets: [target], apply: true)
            .outcomes.allSatisfy(\.succeeded))
        try writeSkillFixture(
            at: root.appendingPathComponent(".agents/skills/demo"),
            name: "demo"
        )

        XCTAssertThrowsError(try MetagentCore.restoreArchivedSkill(named: "demo")) { error in
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
        // The archive entry is untouched and can still be restored later.
        XCTAssertEqual(MetagentCore.listArchivedSkills().map(\.skillName), ["demo"])
    }

    func testRestoreUnknownNameListsWhatIsArchived() throws {
        XCTAssertThrowsError(try MetagentCore.restoreArchivedSkill(named: "missing")) { error in
            XCTAssertTrue(error.localizedDescription.contains("the archive is empty"))
        }
    }

    func testHistoryRecordsArchiveAndRestoreAsTheirOwnKinds() throws {
        let root = try canonicalFixture("history")
        let resolvedRoot = root.resolvingSymlinksInPath()
        let databasePath = try makeTemporaryRoot(prefix: "metagent-archive-history")
            .appendingPathComponent("history.sqlite").path
        let skillPath = resolvedRoot.appendingPathComponent(".agents/skills/demo").path
        let item = SkillInventoryItem.fixture(name: "demo", path: skillPath)
        let present = [SkillProject(
            root: resolvedRoot.path,
            skillsDir: resolvedRoot.appendingPathComponent(".agents/skills").path,
            validSkills: ["demo"],
            skills: [item]
        )]
        let absent = [SkillProject(
            root: resolvedRoot.path,
            skillsDir: resolvedRoot.appendingPathComponent(".agents/skills").path,
            validSkills: [],
            skills: []
        )]
        let usage = SkillUsageSnapshot(
            summaries: [],
            totalInvocations: 0,
            totalFiles: 0,
            completedFiles: 0,
            totalBytes: 0,
            processedBytes: 0,
            isBackfillComplete: true,
            isParserUpgradeBackfill: false,
            displayParserVersion: 1,
            targetParserVersion: 1,
            coverageStartedAt: nil,
            lastUpdatedAt: nil
        )
        func capture(_ projects: [SkillProject], day: String) throws -> SkillHistoryCaptureReport {
            try MetagentCore.captureSkillHistory(
                projects: projects,
                usage: usage,
                trigger: .mutation,
                now: ISO8601DateFormatter().date(from: "\(day)T12:00:00Z")!,
                databasePath: databasePath
            )
        }

        _ = try capture(present, day: "2026-07-20")

        let target = try XCTUnwrap(MetagentCore.resolveSkillRemovalTarget(
            projectRoot: root.path,
            skillName: "demo"
        ))
        XCTAssertTrue(MetagentCore.archiveSkills(targets: [target], apply: true)
            .outcomes.allSatisfy(\.succeeded))
        let afterArchive = try capture(absent, day: "2026-07-21")
        XCTAssertEqual(afterArchive.events.map(\.kind), [.archived])
        XCTAssertEqual(afterArchive.events.map(\.subjectName), ["demo"])

        _ = try MetagentCore.restoreArchivedSkill(named: "demo")
        let afterRestore = try capture(present, day: "2026-07-22")
        XCTAssertEqual(afterRestore.events.map(\.kind), [.restored])

        // A skill that leaves without an archive entry is still a removal.
        try FileManager.default.removeItem(
            at: resolvedRoot.appendingPathComponent(".agents/skills/demo")
        )
        let afterRemoval = try capture(absent, day: "2026-07-23")
        XCTAssertEqual(afterRemoval.events.map(\.kind), [.removed])
    }

    private func canonicalFixture(_ label: String) throws -> URL {
        let root = try makeTemporaryRoot(prefix: "metagent-archive-\(label)")
        try writeSkillFixture(at: root.appendingPathComponent(".agents/skills/demo"), name: "demo")
        let projections = root.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: projections, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: projections.appendingPathComponent("demo").path,
            withDestinationPath: "../../.agents/skills/demo"
        )
        return root
    }
}
