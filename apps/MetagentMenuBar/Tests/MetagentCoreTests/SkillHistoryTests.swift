import Foundation
import Testing
@testable import MetagentCore

@Suite("Skill history")
struct SkillHistoryTests {
    // A fixed UTC calendar keeps day bucketing independent of where the tests run.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func temporaryDatabase() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("history.sqlite").path
    }

    private func project(root: String, skills: [SkillInventoryItem]) -> SkillProject {
        SkillProject(
            root: root,
            skillsDir: "\(root)/.agents/skills",
            validSkills: skills.map(\.name),
            skills: skills
        )
    }

    private func skill(
        name: String,
        root: String,
        scope: String = "global",
        bodyTokens: Int = 100
    ) -> SkillInventoryItem {
        .fixture(
            name: name,
            description: "A useful skill",
            path: "\(root)/.agents/skills/\(name)",
            originKind: scope == "global" ? "user-local" : "project-local",
            scope: scope,
            authority: "local",
            updatedAt: "2026-07-01T12:00:00Z",
            characterCount: bodyTokens * 4,
            wordCount: bodyTokens,
            tokenEstimate: bodyTokens
        )
    }

    private func usage(_ summaries: [SkillUsageSummary]) -> SkillUsageSnapshot {
        SkillUsageSnapshot(
            summaries: summaries,
            totalInvocations: summaries.reduce(0) { $0 + $1.totalInvocations },
            totalFiles: 4,
            completedFiles: 4,
            totalBytes: 1_000,
            processedBytes: 1_000,
            isBackfillComplete: true,
            isParserUpgradeBackfill: false,
            displayParserVersion: 1,
            targetParserVersion: 1,
            coverageStartedAt: "2026-01-01T00:00:00Z",
            lastUpdatedAt: "2026-07-20T00:00:00Z"
        )
    }

    private func usageSummary(name: String, path: String, total: Int, last30d: Int) -> SkillUsageSummary {
        SkillUsageSummary(
            id: "global:\(name)",
            skillName: name,
            canonicalPath: path,
            scope: "global",
            totalInvocations: total,
            invocations7d: last30d,
            invocations30d: last30d,
            activeTurns: total,
            distinctThreads: 1,
            repeatInvocations: 0,
            directInvocations: total,
            inferredInvocations: 0,
            firstUsedAt: "2026-06-01T12:00:00Z",
            lastUsedAt: "2026-07-20T12:00:00Z"
        )
    }

    @Test("records at most one sample per local day and updates it in place")
    func dayBucketing() throws {
        let databasePath = try temporaryDatabase()
        let root = "/Users/tester"
        let projects = [project(root: root, skills: [skill(name: "alpha", root: root)])]

        let morning = try MetagentCore.captureSkillHistory(
            projects: projects,
            usage: usage([]),
            trigger: .launch,
            now: date("2026-07-20T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )
        #expect(morning.isNewDay)

        let evening = try MetagentCore.captureSkillHistory(
            projects: projects,
            usage: usage([]),
            trigger: .refresh,
            now: date("2026-07-20T21:30:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )
        #expect(!evening.isNewDay)
        #expect(evening.day == morning.day)

        let nextDay = try MetagentCore.captureSkillHistory(
            projects: projects,
            usage: usage([]),
            trigger: .refresh,
            now: date("2026-07-21T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )
        #expect(nextDay.isNewDay)

        let series = try MetagentCore.skillHistorySeries(
            metric: .portfolioSkills,
            databasePath: databasePath
        )
        #expect(series.map(\.day) == ["2026-07-20", "2026-07-21"])
        #expect(series.allSatisfy { $0.value == 1 })
    }

    @Test("the first capture seeds state without claiming every skill was added")
    func firstCaptureEmitsNoEvents() throws {
        let databasePath = try temporaryDatabase()
        let root = "/Users/tester"
        let report = try MetagentCore.captureSkillHistory(
            projects: [project(root: root, skills: [
                skill(name: "alpha", root: root),
                skill(name: "beta", root: root),
            ])],
            usage: usage([]),
            trigger: .launch,
            now: date("2026-07-20T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )
        #expect(report.events.isEmpty)
    }

    @Test("derives add, remove, and content-change events from consecutive captures")
    func derivesEvents() throws {
        let databasePath = try temporaryDatabase()
        let root = "/Users/tester"
        _ = try MetagentCore.captureSkillHistory(
            projects: [project(root: root, skills: [
                skill(name: "alpha", root: root),
                skill(name: "beta", root: root),
            ])],
            usage: usage([]),
            trigger: .launch,
            now: date("2026-07-20T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )

        let second = try MetagentCore.captureSkillHistory(
            projects: [project(root: root, skills: [
                skill(name: "alpha", root: root, bodyTokens: 400),
                skill(name: "gamma", root: root),
            ])],
            usage: usage([]),
            trigger: .refresh,
            now: date("2026-07-21T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )

        let byKind = Dictionary(grouping: second.events, by: \.kind)
        #expect(byKind[.added]?.map(\.subjectName) == ["gamma"])
        #expect(byKind[.removed]?.map(\.subjectName) == ["beta"])
        #expect(byKind[.contentChanged]?.map(\.subjectName) == ["alpha"])

        let stored = try MetagentCore.skillHistoryEvents(databasePath: databasePath)
        #expect(stored.count == 3)
        #expect(stored.allSatisfy { $0.origin == .observed })
    }

    @Test("pairs a moved bundle as one rename rather than a removal and an addition")
    func detectsRename() throws {
        let databasePath = try temporaryDatabase()
        // The pairing is proved by the directory's inode, so this needs real
        // folders and a real move rather than fixture paths.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-rename-\(UUID().uuidString)")
        let skillsDir = root.appendingPathComponent(".agents/skills")
        try FileManager.default.createDirectory(
            at: skillsDir.appendingPathComponent("alpha"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try MetagentCore.captureSkillHistory(
            projects: [project(root: root.path, skills: [skill(name: "alpha", root: root.path)])],
            usage: usage([]),
            trigger: .launch,
            now: date("2026-07-20T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )

        try FileManager.default.moveItem(
            at: skillsDir.appendingPathComponent("alpha"),
            to: skillsDir.appendingPathComponent("alpha-renamed")
        )
        let renamed = try MetagentCore.captureSkillHistory(
            projects: [project(root: root.path, skills: [
                skill(name: "alpha-renamed", root: root.path),
            ])],
            usage: usage([]),
            trigger: .mutation,
            now: date("2026-07-21T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )
        #expect(renamed.events.count == 1)
        #expect(renamed.events.first?.kind == .renamed)
        #expect(renamed.events.first?.detail["from"] == "alpha")
        #expect(renamed.events.first?.subjectName == "alpha-renamed")
    }

    @Test("does not mistake two same-sized skills for a rename")
    func doesNotPairUnrelatedSkills() throws {
        let databasePath = try temporaryDatabase()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-rename-\(UUID().uuidString)")
        let skillsDir = root.appendingPathComponent(".agents/skills")
        for name in ["beta", "gamma"] {
            try FileManager.default.createDirectory(
                at: skillsDir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try MetagentCore.captureSkillHistory(
            projects: [project(root: root.path, skills: [skill(name: "beta", root: root.path)])],
            usage: usage([]),
            trigger: .launch,
            now: date("2026-07-20T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )
        // Identical fixture stats, different directories: a rename heuristic
        // based on content alone would wrongly pair these.
        let second = try MetagentCore.captureSkillHistory(
            projects: [project(root: root.path, skills: [skill(name: "gamma", root: root.path)])],
            usage: usage([]),
            trigger: .refresh,
            now: date("2026-07-21T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )
        let kinds = Set(second.events.map(\.kind))
        #expect(kinds == [.added, .removed])
    }

    @Test("leaves days with no sample absent instead of interpolating them")
    func gapsStayGaps() throws {
        let databasePath = try temporaryDatabase()
        let root = "/Users/tester"
        let projects = [project(root: root, skills: [skill(name: "alpha", root: root)])]
        for day in ["2026-07-20T09:00:00Z", "2026-07-25T09:00:00Z"] {
            _ = try MetagentCore.captureSkillHistory(
                projects: projects,
                usage: usage([]),
                trigger: .refresh,
                now: date(day),
                calendar: calendar,
                databasePath: databasePath
            )
        }
        let series = try MetagentCore.skillHistorySeries(
            metric: .portfolioSkills,
            databasePath: databasePath
        )
        #expect(series.map(\.day) == ["2026-07-20", "2026-07-25"])
    }

    @Test("omits adoption metrics when no session corpus is indexed")
    func skipsAdoptionWithoutCorpus() throws {
        let databasePath = try temporaryDatabase()
        let root = "/Users/tester"
        _ = try MetagentCore.captureSkillHistory(
            projects: [project(root: root, skills: [skill(name: "alpha", root: root)])],
            usage: .empty,
            trigger: .launch,
            now: date("2026-07-20T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )
        let unused = try MetagentCore.skillHistorySeries(
            metric: .adoptionUnused30d,
            databasePath: databasePath
        )
        // Absent, not zero: an unindexed machine has not proved anything unused.
        #expect(unused.isEmpty)
        let installed = try MetagentCore.skillHistorySeries(
            metric: .portfolioSkills,
            databasePath: databasePath
        )
        #expect(installed.count == 1)
    }

    @Test("records the health summary the Overview would show")
    func matchesHealthSummary() throws {
        let databasePath = try temporaryDatabase()
        let root = "/Users/tester"
        let skills = [
            skill(name: "alpha", root: root, bodyTokens: 100),
            skill(name: "beta", root: root, bodyTokens: 300),
        ]
        let projects = [project(root: root, skills: skills)]
        let snapshot = usage([
            usageSummary(name: "alpha", path: "\(root)/.agents/skills/alpha", total: 5, last30d: 2),
        ])
        let now = date("2026-07-20T09:00:00Z")
        _ = try MetagentCore.captureSkillHistory(
            projects: projects,
            usage: snapshot,
            trigger: .launch,
            now: now,
            calendar: calendar,
            databasePath: databasePath
        )
        let expected = MetagentCore.skillSystemHealth(
            projects: projects,
            usage: snapshot,
            scope: .all,
            now: now
        )
        func value(_ metric: SkillHistoryMetric) throws -> Double? {
            try MetagentCore.skillHistorySeries(metric: metric, databasePath: databasePath).first?.value
        }
        #expect(try value(.portfolioSkills) == Double(expected.skillCount))
        #expect(try value(.tokensSkillBody) == Double(expected.skillBodyTokenEstimate))
        #expect(try value(.adoptionUnused30d) == Double(expected.unused30dSkillCount))
        #expect(try value(.adoptionNeverObserved) == Double(expected.neverObservedSkillCount))
    }

    @Test("reports observed and reconstructed coverage separately")
    func reportsCoverage() throws {
        let databasePath = try temporaryDatabase()
        let root = "/Users/tester"
        _ = try MetagentCore.captureSkillHistory(
            projects: [project(root: root, skills: [skill(name: "alpha", root: root)])],
            usage: usage([]),
            trigger: .launch,
            now: date("2026-07-20T09:00:00Z"),
            calendar: calendar,
            databasePath: databasePath
        )
        let coverage = try MetagentCore.skillHistoryCoverage(databasePath: databasePath)
        #expect(coverage.observedDayCount == 1)
        #expect(coverage.inferredDayCount == 0)
        #expect(coverage.firstObservedDay == "2026-07-20")
    }
}

@Suite("Skill history backfill")
struct SkillHistoryBackfillTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("counts a removed skill for the days it was actually installed")
    func removedSkillsSpanTheirLifetime() {
        let alive = [
            ReconstructedSkill(
                key: "/Users/tester/.agents/skills/alpha",
                name: "alpha",
                scope: "global",
                installedOn: "2026-05-01",
                removedOn: "2026-06-01"
            ),
        ]
        let onlyBefore = alive.filter { skill in
            skill.installedOn <= "2026-05-15" && (skill.removedOn.map { "2026-05-15" < $0 } ?? true)
        }
        #expect(onlyBefore.count == 1)
        let afterRemoval = alive.filter { skill in
            skill.installedOn <= "2026-06-15" && (skill.removedOn.map { "2026-06-15" < $0 } ?? true)
        }
        #expect(afterRemoval.isEmpty)
    }

    @Test("reads install and removal dates out of the recovery archive")
    func readsRemovalArchive() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-archive-\(UUID().uuidString)")
        let entry = archive.appendingPathComponent(UUID().uuidString)
        let bundle = entry.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archive) }
        try """
        project=/Users/tester/code/sample
        skill=legacy
        removed_at=2026-06-04T10:00:00Z
        """.write(
            to: entry.appendingPathComponent("REMOVAL.txt"),
            atomically: true,
            encoding: .utf8
        )

        let removals = reconstructedRemovals(archive: archive, calendar: calendar)
        #expect(removals.count == 1)
        #expect(removals[0].name == "legacy")
        #expect(removals[0].scope == "project")
        #expect(removals[0].removedOn == "2026-06-04")
        // The archived bundle was created during this test, so its creation date
        // is later than the recorded removal; the lifetime is clamped rather
        // than inverted.
        #expect(removals[0].installedOn <= removals[0].removedOn!)
    }

    @Test("reconstructs adoption from timestamped reads only")
    func reconstructsAdoption() {
        let alive = [
            ReconstructedSkill(
                key: "/Users/tester/.agents/skills/alpha",
                name: "alpha",
                scope: "global",
                installedOn: "2026-05-01",
                removedOn: nil
            ),
            ReconstructedSkill(
                key: "/Users/tester/.agents/skills/beta",
                name: "beta",
                scope: "global",
                installedOn: "2026-05-01",
                removedOn: nil
            ),
        ]
        let reads = [
            "/Users/tester/.agents/skills/alpha": ["2026-06-10": 3, "2026-04-01": 2],
        ]
        let metrics = reconstructedMetrics(
            alive: alive,
            day: "2026-06-20",
            readsByKeyDay: reads,
            hasUsageCorpus: true,
            calendar: calendar
        )
        func value(_ metric: SkillHistoryMetric) -> Double? {
            metrics.first { $0.scope == SkillHistoryScope.all.key && $0.metric == metric }?.value
        }
        #expect(value(.portfolioSkills) == 2)
        // alpha read 5 times overall, only 3 of them inside the 30-day window.
        #expect(value(.adoptionObserved) == 1)
        #expect(value(.adoptionActive30d) == 1)
        #expect(value(.adoptionNeverObserved) == 1)
        #expect(value(.adoptionUnused30d) == 1)
    }

    @Test("records no adoption metrics when the usage corpus is missing")
    func withoutCorpusOnlyCounts() {
        let alive = [
            ReconstructedSkill(
                key: "/Users/tester/.agents/skills/alpha",
                name: "alpha",
                scope: "global",
                installedOn: "2026-05-01",
                removedOn: nil
            ),
        ]
        let metrics = reconstructedMetrics(
            alive: alive,
            day: "2026-06-20",
            readsByKeyDay: [:],
            hasUsageCorpus: false,
            calendar: calendar
        )
        #expect(metrics.contains { $0.metric == .portfolioSkills })
        #expect(!metrics.contains { $0.metric == .adoptionUnused30d })
    }

    @Test("never overwrites an observed day with a reconstructed one")
    func observedWinsOverInferred() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("history.sqlite").path
        let store = try SkillHistoryStore(path: databasePath)

        try store.record(
            day: "2026-07-20",
            capturedAt: ISO8601DateFormatter().date(from: "2026-07-20T09:00:00Z")!,
            trigger: .launch,
            origin: .observed,
            metrics: [(SkillHistoryScope.all.key, .portfolioSkills, 42)],
            states: nil
        )
        try store.record(
            day: "2026-07-20",
            capturedAt: ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z")!,
            trigger: .backfill,
            origin: .inferred,
            metrics: [(SkillHistoryScope.all.key, .portfolioSkills, 7)],
            states: nil
        )

        let series = try MetagentCore.skillHistorySeries(
            metric: .portfolioSkills,
            databasePath: databasePath
        )
        #expect(series.count == 1)
        #expect(series[0].value == 42)
        #expect(series[0].origin == .observed)
    }

    @Test("parses name-status output into per-file changes")
    func parsesGitLog() {
        let output = """
        C|abc123|2026-07-24

        A\tskills/alpha/SKILL.md
        D\tskills/beta/SKILL.md
        C|def456|2026-07-20

        M\tskills/alpha/references/guide.md
        """
        let changes = parseGitSkillLog(output)
        #expect(changes.count == 3)
        #expect(changes[0] == GitChange(day: "2026-07-24", status: "A", path: "skills/alpha/SKILL.md"))
        #expect(changes[1] == GitChange(day: "2026-07-24", status: "D", path: "skills/beta/SKILL.md"))
        #expect(changes[2].day == "2026-07-20")
        #expect(changes[2].status == "M")
    }

    @Test("splits a rename into a deletion and an addition")
    func parsesRenameAsDeleteAndAdd() {
        let output = """
        C|abc123|2026-07-24

        R100\tskills/old-name/SKILL.md\tskills/new-name/SKILL.md
        """
        let changes = parseGitSkillLog(output)
        #expect(changes.count == 2)
        #expect(changes[0] == GitChange(day: "2026-07-24", status: "D", path: "skills/old-name/SKILL.md"))
        #expect(changes[1] == GitChange(day: "2026-07-24", status: "A", path: "skills/new-name/SKILL.md"))
    }

    @Test("ignores output before the first commit header")
    func ignoresHeaderlessChanges() {
        #expect(parseGitSkillLog("M\tskills/alpha/SKILL.md").isEmpty)
    }

    @Test("surfaces git deletions the removal archive never recorded")
    func gitFindsRemovalsTheArchiveMissed() {
        let lifetimes = [
            "/repo/.agents/skills/gone": GitSkillLifetime(
                skillKey: "/repo/.agents/skills/gone",
                name: "gone",
                installedOn: "2026-03-01",
                removedOn: "2026-05-01",
                changedOn: []
            ),
            "/repo/.agents/skills/present": GitSkillLifetime(
                skillKey: "/repo/.agents/skills/present",
                name: "present",
                installedOn: "2026-03-01",
                removedOn: nil,
                changedOn: ["2026-04-02"]
            ),
        ]
        let removals = gitOnlyRemovals(
            gitLifetimes: lifetimes,
            installedKeys: ["/repo/.agents/skills/present"]
        )
        #expect(removals.count == 1)
        #expect(removals[0].name == "gone")
        #expect(removals[0].installedOn == "2026-03-01")
        #expect(removals[0].removedOn == "2026-05-01")
    }

    @Test("does not report a skill as removed when git shows it still installed")
    func skipsStillInstalledSkills() {
        let lifetimes = [
            "/repo/.agents/skills/alpha": GitSkillLifetime(
                skillKey: "/repo/.agents/skills/alpha",
                name: "alpha",
                installedOn: "2026-03-01",
                removedOn: "2026-05-01",
                changedOn: []
            ),
        ]
        // Present on disk now, so the recorded deletion was undone by a later
        // re-add that predates the scan.
        #expect(gitOnlyRemovals(
            gitLifetimes: lifetimes,
            installedKeys: ["/repo/.agents/skills/alpha"]
        ).isEmpty)
    }

    @Test("day arithmetic stays stable across a daylight saving transition")
    func dayRangeAcrossDSTShift() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let days = historyDayRange(from: "2026-03-07", through: "2026-03-10", calendar: pacific)
        #expect(days == ["2026-03-07", "2026-03-08", "2026-03-09", "2026-03-10"])
    }

    @Test("stamps a reconstructed day at midday so no timezone shifts its date")
    func reconstructedTimestampsStayOnTheirDay() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let stamped = middayOf("2026-07-20", calendar: pacific)!
        #expect(historyDay(stamped, calendar: pacific) == "2026-07-20")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(historyDay(stamped, calendar: utc) == "2026-07-20")
    }
}
