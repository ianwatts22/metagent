import Darwin
import Foundation
import SQLite3
import XCTest
@testable import MetagentCore

/// Opt-in wall-clock coverage for the core paths that dominate a refresh.
///
/// Keep these tests out of the normal fast lane: filesystem and subprocess
/// timings are useful only when repeated on the same machine and build mode.
final class MetagentCorePerformanceTests: XCTestCase {
    private var runsPerformanceTests: Bool {
        ProcessInfo.processInfo.environment["METAGENT_RUN_PERFORMANCE_TESTS"] == "1"
    }

    private var measureOptions: XCTMeasureOptions {
        let configured = Int(
            ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_ITERATIONS"] ?? ""
        ) ?? 5
        let options = XCTMeasureOptions()
        options.iterationCount = min(max(configured, 1), 20)
        return options
    }

    func testPerformanceSkillPortfolioScan() throws {
        guard runsPerformanceTests else { return }
        let fixture = try makeSkillPortfolio(projectCount: 24, skillsPerProject: 8)
        let options = SkillScanOptions(
            roots: [fixture.path],
            maxDepth: 2,
            respectConfiguredIgnores: false
        )
        let preflight = try assertLatencyBudget(
            "skill portfolio scan",
            seconds: 2.0
        ) {
            try MetagentCore.scanSkills(options: options)
        }
        XCTAssertEqual(preflight.projects.count, 24)
        var lastReport: SkillScanReport?

        measure(metrics: performanceMetrics, options: measureOptions) {
            lastReport = try! MetagentCore.scanSkills(options: options)
        }

        XCTAssertEqual(lastReport?.projects.count, 24)
        XCTAssertEqual(lastReport?.projects.flatMap(\.skills).count, 192)
    }

    func testPerformanceDoctorPortfolioAudit() throws {
        guard runsPerformanceTests else { return }
        let fixture = try makeSkillPortfolio(projectCount: 24, skillsPerProject: 8)
        let options = SkillScanOptions(
            roots: [fixture.path],
            maxDepth: 2,
            respectConfiguredIgnores: false
        )
        let preflight = try assertLatencyBudget(
            "Doctor portfolio audit",
            seconds: 2.0
        ) {
            try MetagentCore.doctor(options: options)
        }
        XCTAssertEqual(preflight.failureCount, 0)
        var lastReport: DoctorReport?

        measure(metrics: performanceMetrics, options: measureOptions) {
            lastReport = try! MetagentCore.doctor(options: options)
        }

        XCTAssertEqual(
            lastReport?.issues.filter { $0.severity == .ok && $0.category == .skills }.count,
            24
        )
        XCTAssertEqual(lastReport?.failureCount, 0)
    }

    func testPerformanceSkillOverlapPortfolio() throws {
        guard runsPerformanceTests else { return }
        // Shared skill names across projects exercise the pairwise comparison
        // path. Keep discovery outside the measurement: this is the work done
        // when the Skills table already has an inventory snapshot.
        let fixture = try makeSkillPortfolio(projectCount: 24, skillsPerProject: 8)
        let report = try MetagentCore.scanSkills(options: SkillScanOptions(
            roots: [fixture.path],
            maxDepth: 2,
            respectConfiguredIgnores: false
        ))
        let skills = report.projects.flatMap(\.skills)
        XCTAssertEqual(skills.count, 192)
        let preflight = assertLatencyBudget("skill overlap portfolio", seconds: 0.5) {
            MetagentCore.detectSkillOverlaps(skills)
        }
        XCTAssertEqual(preflight.count, 8)
        XCTAssertTrue(preflight.allSatisfy { $0.members.count == 24 })
        var lastGroups: [SkillOverlapGroup] = []

        measure(metrics: performanceMetrics, options: measureOptions) {
            lastGroups = MetagentCore.detectSkillOverlaps(skills)
        }

        XCTAssertEqual(lastGroups, preflight)
    }

    func testPerformanceConfiguredAndHomeInventoryDiscovery() throws {
        guard runsPerformanceTests else { return }
        let home = try makeTemporaryRoot(prefix: "metagent-performance-app-refresh")
        let configuredRoot = home.appendingPathComponent("code_projects")
        for projectIndex in 0..<12 {
            for skillIndex in 0..<8 {
                try writeSkillFixture(
                    at: configuredRoot.appendingPathComponent(
                        "group-\(projectIndex / 4)/project-\(projectIndex)/.agents/skills/skill-\(skillIndex)"
                    ),
                    name: "skill-\(skillIndex)",
                    description: "Configured refresh fixture \(projectIndex)-\(skillIndex)"
                )
            }
        }
        try writeSkillFixture(
            at: home.appendingPathComponent(".agents/skills/global-skill"),
            name: "global-skill"
        )
        try writeSkillFixture(
            at: home.appendingPathComponent("Desktop/example/.agents/skills/desktop-skill"),
            name: "desktop-skill"
        )

        let config = MetagentConfig(roots: [configuredRoot.path], maxDepth: 6)
        let options = SkillScanOptions(
            roots: config.roots,
            maxDepth: config.maxDepth,
            respectConfiguredIgnores: false
        )
        var lastConfigured: SkillScanReport?
        var lastHome: SkillScanReport?
        let refresh = {
            lastConfigured = try MetagentCore.scanSkills(options: options, config: config)
            lastHome = try MetagentCore.scanHomeSkills(
                home: home,
                maxDepth: 2,
                pruningConfiguredRoots: true,
                config: config
            )
        }

        try assertLatencyBudget(
            "configured and home inventory discovery",
            seconds: 2.0,
            operation: refresh
        )
        XCTAssertEqual(lastConfigured?.projects.count, 12)
        XCTAssertEqual(Set(lastHome?.projects.map(\.root) ?? []), Set([
            home.path,
            home.appendingPathComponent("Desktop/example").path,
        ]))

        measure(metrics: performanceMetrics, options: measureOptions) {
            try! refresh()
        }

        XCTAssertEqual(lastConfigured?.projects.flatMap(\.skills).count, 96)
        XCTAssertEqual(lastHome?.projects.flatMap(\.skills).count, 2)
    }

    func testPerformanceTrackedCodebaseMeasurement() throws {
        guard runsPerformanceTests else { return }
        let fixture = try makeTrackedCodebase(fileCount: 250, linesPerFile: 40)
        let preflight = try assertLatencyBudget(
            "tracked codebase measurement",
            seconds: 1.0
        ) {
            try MetagentCore.measureCodebaseSize(root: fixture.path)
        }
        XCTAssertEqual(preflight.totalFiles, 251)
        var lastReport: CodebaseSizeReport?

        measure(metrics: performanceMetrics, options: measureOptions) {
            lastReport = try! MetagentCore.measureCodebaseSize(root: fixture.path)
        }

        XCTAssertEqual(lastReport?.totalFiles, 251)
        XCTAssertEqual(lastReport?.codeLines, 8_000)
        XCTAssertEqual(lastReport?.lines(in: .tests), 2_000)
    }

    func testPerformanceColdUsageBackfill() throws {
        guard runsPerformanceTests else { return }
        let fixture = try makeUsageBackfillFixture(sessionCount: 10, readsPerSession: 30)
        let preflight = try assertLatencyBudget("cold usage refresh", seconds: 1.0) {
            try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
                sessionRoots: [fixture.sessions.path],
                databasePath: fixture.root.appendingPathComponent("preflight.sqlite").path,
                maxBytes: 16 * 1_024 * 1_024,
                maxFiles: 20
            ))
        }
        XCTAssertEqual(preflight.snapshot.totalInvocations, 300)

        // XCTest may perform unreported calibration invocations around the
        // configured sample count, so keep spare cold databases available.
        let databasePaths = (0..<25).map {
            fixture.root.appendingPathComponent("usage-\($0).sqlite").path
        }
        var iteration = 0
        var lastReport: SkillUsageRefreshReport?

        measure(metrics: performanceMetrics, options: measureOptions) {
            let databasePath = databasePaths[iteration]
            iteration += 1
            lastReport = try! MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
                sessionRoots: [fixture.sessions.path],
                databasePath: databasePath,
                maxBytes: 16 * 1_024 * 1_024,
                maxFiles: 20
            ))
        }

        XCTAssertEqual(lastReport?.filesRead, 10)
        XCTAssertEqual(lastReport?.snapshot.totalInvocations, 300)
        XCTAssertEqual(lastReport?.snapshot.summaries.count, 20)
        XCTAssertEqual(lastReport?.hasMore, false)
    }

    func testPerformanceUsageParserSkipsHighVolumeNoise() throws {
        guard runsPerformanceTests else { return }
        let fixture = try makeNoisyUsageFixture(
            sessionCount: 8,
            irrelevantRecordsPerSession: 2_500,
            readsPerSession: 5
        )
        let preflight = try assertLatencyBudget("noisy usage parsing", seconds: 1.0) {
            try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
                sessionRoots: [fixture.sessions.path],
                databasePath: fixture.root.appendingPathComponent("noise-preflight.sqlite").path,
                maxBytes: 32 * 1_024 * 1_024,
                maxFiles: 20
            ))
        }
        XCTAssertEqual(preflight.snapshot.totalInvocations, 40)

        let databasePaths = (0..<25).map {
            fixture.root.appendingPathComponent("noise-usage-\($0).sqlite").path
        }
        var iteration = 0
        var lastReport: SkillUsageRefreshReport?

        measure(metrics: performanceMetrics, options: measureOptions) {
            let databasePath = databasePaths[iteration]
            iteration += 1
            lastReport = try! MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
                sessionRoots: [fixture.sessions.path],
                databasePath: databasePath,
                maxBytes: 32 * 1_024 * 1_024,
                maxFiles: 20
            ))
        }

        XCTAssertEqual(lastReport?.filesRead, 8)
        XCTAssertEqual(lastReport?.snapshot.totalInvocations, 40)
        XCTAssertEqual(lastReport?.snapshot.summaries.count, 10)
        XCTAssertEqual(lastReport?.hasMore, false)
    }

    func testPerformanceUsageBacklogConvergence() throws {
        guard runsPerformanceTests else { return }
        let fixture = try makeUsageBackfillFixture(sessionCount: 36, readsPerSession: 20)
        let databasePaths = (0..<25).map {
            fixture.root.appendingPathComponent("convergence-usage-\($0).sqlite").path
        }
        var iteration = 0
        var lastReport: SkillUsageRefreshReport?
        var lastSliceCount = 0

        let preflight = try assertLatencyBudget("bounded usage backlog convergence", seconds: 4.0) {
            try convergeUsageBacklog(
                sessions: fixture.sessions.path,
                database: fixture.root.appendingPathComponent("convergence-preflight.sqlite").path
            )
        }
        XCTAssertEqual(preflight.report.snapshot.totalInvocations, 720)
        XCTAssertEqual(preflight.slices, 3)

        measure(metrics: performanceMetrics, options: measureOptions) {
            let result = try! convergeUsageBacklog(
                sessions: fixture.sessions.path,
                database: databasePaths[iteration]
            )
            iteration += 1
            lastReport = result.report
            lastSliceCount = result.slices
        }

        XCTAssertEqual(lastReport?.snapshot.totalInvocations, 720)
        XCTAssertEqual(lastReport?.snapshot.completedFiles, 36)
        XCTAssertEqual(lastReport?.hasMore, false)
        XCTAssertEqual(lastSliceCount, 3)
    }

    func testPerformanceWarmUsageSourceDiscovery() throws {
        guard runsPerformanceTests else { return }
        let root = try makeTemporaryRoot(prefix: "metagent-performance-usage-discovery")
        let sessions = root.appendingPathComponent("sessions")
        for index in 0..<15_456 {
            try write(
                "",
                to: sessions.appendingPathComponent(
                    "2026/08/\(index % 28 + 1)/rollout-\(index).jsonl"
                )
            )
        }
        let database = root.appendingPathComponent("usage.sqlite").path
        let options = SkillUsageRefreshOptions(
            sessionRoots: [sessions.path],
            databasePath: database,
            maxBytes: 1_024 * 1_024,
            maxFiles: 12
        )
        let preflight = try assertLatencyBudget(
            "warm usage source discovery",
            seconds: 1.0
        ) {
            try MetagentCore.refreshSkillUsage(options: options)
        }
        XCTAssertEqual(preflight.snapshot.totalFiles, 15_456)
        XCTAssertEqual(preflight.filesRead, 0)
        var lastReport: SkillUsageRefreshReport?

        measure(metrics: performanceMetrics, options: measureOptions) {
            lastReport = try! MetagentCore.refreshSkillUsage(options: options)
        }

        XCTAssertEqual(lastReport?.snapshot.totalFiles, 15_456)
        XCTAssertEqual(lastReport?.filesRead, 0)
        XCTAssertEqual(lastReport?.hasMore, false)
    }

    func testPerformanceWarmUsageStateMaintenance() throws {
        guard runsPerformanceTests else { return }
        let root = try makeTemporaryRoot(prefix: "metagent-performance-usage-state")
        let sessions = root.appendingPathComponent("sessions")
        let database = root.appendingPathComponent("usage.sqlite").path
        _ = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [sessions.path],
            databasePath: database
        ))
        let sourceCount = 15_456
        var sourcePaths: [String] = []
        sourcePaths.reserveCapacity(sourceCount)
        for index in 0..<sourceCount {
            let source = sessions.appendingPathComponent(
                "2026/08/\(index % 28 + 1)/rollout-\(index).jsonl"
            )
            try write("", to: source)
            sourcePaths.append(source.path)
        }
        try seedCompletedUsageSources(sourcePaths, database: database)
        let options = SkillUsageRefreshOptions(
            sessionRoots: [sessions.path],
            databasePath: database,
            maxBytes: 1_024 * 1_024,
            maxFiles: 12
        )
        let preflight = try assertLatencyBudget(
            "15k-source first persisted-state maintenance",
            seconds: 1.25
        ) {
            try MetagentCore.refreshSkillUsage(options: options)
        }
        XCTAssertEqual(preflight.snapshot.totalFiles, sourceCount)
        XCTAssertEqual(preflight.snapshot.completedFiles, sourceCount)
        XCTAssertEqual(preflight.filesRead, 0)
        XCTAssertEqual(try usageSourceRowCount(database: database), sourceCount)
        var lastReport: SkillUsageRefreshReport?

        measure(metrics: performanceMetrics, options: measureOptions) {
            lastReport = try! MetagentCore.refreshSkillUsage(options: options)
        }

        XCTAssertEqual(lastReport?.snapshot.completedFiles, sourceCount)
        XCTAssertEqual(lastReport?.filesRead, 0)
        XCTAssertEqual(lastReport?.hasMore, false)
    }

    func testPerformanceUsageContinuationReusesOneDiscoveryAcrossSevenSlices() throws {
        guard runsPerformanceTests else { return }
        MetagentCore.resetSkillUsageSourceCatalogForTesting()
        defer { MetagentCore.resetSkillUsageSourceCatalogForTesting() }
        let root = try makeTemporaryRoot(prefix: "metagent-performance-usage-continuation")
        let sessions = root.appendingPathComponent("sessions")
        let database = root.appendingPathComponent("usage.sqlite").path
        _ = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [sessions.path],
            databasePath: database
        ))
        let sourceCount = 15_456
        var sourcePaths: [String] = []
        sourcePaths.reserveCapacity(sourceCount)
        for index in 0..<sourceCount {
            let source = sessions.appendingPathComponent(
                "2026/08/\(index % 28 + 1)/rollout-\(index).jsonl"
            )
            try write("", to: source)
            sourcePaths.append(source.path)
        }
        try seedCompletedUsageSources(sourcePaths, database: database)
        try writeUsageNoise(
            minimumBytes: 55 * 1_024 * 1_024,
            to: URL(fileURLWithPath: sourcePaths[0])
        )
        MetagentCore.resetSkillUsageSourceCatalogForTesting()
        let options = SkillUsageRefreshOptions(
            sessionRoots: [sessions.path],
            databasePath: database,
            maxBytes: 8 * 1_024 * 1_024,
            maxFiles: 12,
            reusesSourceCatalog: true
        )
        var reports: [SkillUsageRefreshReport] = []
        try assertLatencyBudget(
            "15k-source seven-slice usage continuation",
            seconds: 4.0
        ) {
            for slice in 0..<7 {
                reports.append(try MetagentCore.refreshSkillUsage(options: options))
                if slice == 0 {
                    // Real maintenance continuations are separated by tens of
                    // seconds. Expose delayed stream callbacks here so the rail
                    // cannot pass by outrunning catalog invalidation.
                    usleep(250_000)
                }
            }
        }

        print("[Metagent performance] continuation slice bytes: \(reports.map(\.processedBytesAdvanced))")
        XCTAssertEqual(reports.count, 7)
        XCTAssertTrue(reports.dropLast().allSatisfy(\.hasMore))
        XCTAssertEqual(reports.last?.hasMore, false)
        XCTAssertTrue(reports.dropLast().allSatisfy {
            // A slice may rewind one partial JSONL record at its boundary.
            $0.processedBytesAdvanced >= options.maxBytes - 1_024
        })
        XCTAssertGreaterThan(reports.last?.processedBytesAdvanced ?? 0, 0)
        XCTAssertGreaterThanOrEqual(
            reports.reduce(Int64(0)) { $0 + $1.processedBytesAdvanced },
            55 * 1_024 * 1_024
        )
        XCTAssertEqual(
            MetagentCore.skillUsageSourceDiscoveryCountForTesting(databasePath: database),
            1
        )
        XCTAssertEqual(reports.last?.snapshot.totalFiles, sourceCount)
        XCTAssertEqual(reports.last?.snapshot.completedFiles, sourceCount)
    }

    func testPerformanceUsageSnapshotAggregation() throws {
        guard runsPerformanceTests else { return }
        let fixture = try makeUsageBackfillFixture(sessionCount: 60, readsPerSession: 300)
        let database = fixture.root.appendingPathComponent("snapshot-usage.sqlite").path
        let indexed = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
            sessionRoots: [fixture.sessions.path],
            databasePath: database,
            maxBytes: 64 * 1_024 * 1_024,
            maxFiles: 100
        ))
        XCTAssertEqual(indexed.snapshot.totalInvocations, 18_000)

        let preflight = try assertLatencyBudget(
            "18k-event usage snapshot aggregation",
            seconds: 0.5
        ) {
            try XCTUnwrap(MetagentCore.loadSkillUsageSnapshot(databasePath: database))
        }
        XCTAssertEqual(preflight.summaries.count, 20)
        let materialized = try assertLatencyBudget(
            "18k-event materialized launch usage snapshot",
            seconds: 0.02
        ) {
            try XCTUnwrap(MetagentCore.loadCachedSkillUsageSnapshot(databasePath: database))
        }
        XCTAssertEqual(materialized, indexed.snapshot)
        var lastSnapshot: SkillUsageSnapshot?

        measure(metrics: performanceMetrics, options: measureOptions) {
            lastSnapshot = MetagentCore.loadSkillUsageSnapshot(databasePath: database)
        }

        XCTAssertEqual(lastSnapshot?.totalInvocations, 18_000)
        XCTAssertEqual(lastSnapshot?.summaries.count, 20)
    }

    // MARK: - Realistic, deterministic fixtures

    private var performanceMetrics: [any XCTMetric] {
        [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric(),
            XCTStorageMetric()
        ]
    }

    /// These are broad regression rails, not product claims. XCTest metrics
    /// provide the precise trend; the budget catches a large latency loss even
    /// when no Xcode machine baseline is installed.
    private func assertLatencyBudget<T>(
        _ label: String,
        seconds: TimeInterval,
        operation: () throws -> T
    ) rethrows -> T {
        let configuredMultiplier = Double(
            ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_BUDGET_MULTIPLIER"] ?? ""
        ) ?? 1
        let multiplier = min(max(configuredMultiplier, 0.5), 10)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try operation()
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        print(
            "[Metagent performance] \(label): "
                + "\(String(format: "%.3f", elapsed))s "
                + "(budget \(String(format: "%.3f", seconds * multiplier))s)"
        )
        XCTAssertLessThanOrEqual(
            elapsed,
            seconds * multiplier,
            "\(label) took \(String(format: "%.3f", elapsed))s; budget is \(String(format: "%.3f", seconds * multiplier))s"
        )
        return result
    }

    private func convergeUsageBacklog(
        sessions: String,
        database: String
    ) throws -> (report: SkillUsageRefreshReport, slices: Int) {
        let plan = SkillUsageMaintenancePlan.recommended(isEnergyConstrained: false)
        var report: SkillUsageRefreshReport?
        var slices = 0
        repeat {
            let next = try MetagentCore.refreshSkillUsage(options: SkillUsageRefreshOptions(
                sessionRoots: [sessions],
                databasePath: database,
                maxBytes: plan.maxBytes,
                maxFiles: plan.maxFiles,
                throttleEveryBytes: plan.throttleEveryBytes,
                throttleDelayMilliseconds: plan.throttleDelayMilliseconds
            ))
            XCTAssertLessThanOrEqual(next.filesRead, plan.maxFiles)
            XCTAssertGreaterThan(next.processedBytesAdvanced, 0)
            report = next
            slices += 1
            XCTAssertLessThanOrEqual(slices, 4, "bounded refreshes stopped converging")
        } while report?.hasMore == true
        return (try XCTUnwrap(report), slices)
    }

    private func makeSkillPortfolio(projectCount: Int, skillsPerProject: Int) throws -> URL {
        let root = try makeTemporaryRoot(prefix: "metagent-performance-portfolio")
        for projectIndex in 0..<projectCount {
            let project = root.appendingPathComponent("group-\(projectIndex / 6)/project-\(projectIndex)")
            for skillIndex in 0..<skillsPerProject {
                let skill = project.appendingPathComponent(".agents/skills/skill-\(skillIndex)")
                try writeSkillFixture(
                    at: skill,
                    name: "skill-\(skillIndex)",
                    description: "Handle workflow \(skillIndex) for project \(projectIndex).",
                    body: String(repeating: "Use the project context and return concise evidence.\n", count: 12)
                )
                try write(
                    String(repeating: "Reference detail for the workflow.\n", count: 20),
                    to: skill.appendingPathComponent("references/guide.md")
                )
                try write(
                    "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' verified\n",
                    to: skill.appendingPathComponent("scripts/verify.sh")
                )
            }
        }
        return root
    }

    private func makeTrackedCodebase(fileCount: Int, linesPerFile: Int) throws -> URL {
        let root = try makeTemporaryRoot(prefix: "metagent-performance-codebase")
        try runGit(["init", "--quiet"], in: root)
        for index in 0..<fileCount {
            let isTest = index.isMultiple(of: 5)
            let directory = isTest ? "Tests" : "Sources"
            let line = isTest ? "func testFixture() {}\n" : "func fixture() {}\n"
            try write(
                String(repeating: line, count: linesPerFile),
                to: root.appendingPathComponent("\(directory)/File\(index).swift")
            )
        }
        try write(
            String(repeating: "Performance fixture documentation.\n", count: 100),
            to: root.appendingPathComponent("README.md")
        )
        try runGit(["add", "--all"], in: root)
        return root
    }

    private func makeUsageBackfillFixture(
        sessionCount: Int,
        readsPerSession: Int
    ) throws -> (root: URL, sessions: URL) {
        let root = try makeTemporaryRoot(prefix: "metagent-performance-usage")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let skills = try (0..<20).map { index in
            try writeSkillFixture(
                at: root.appendingPathComponent("workspace/.agents/skills/skill-\(index)"),
                name: "skill-\(index)",
                description: "Performance fixture \(index)",
                body: String(repeating: "Follow the measured workflow.\n", count: 8)
            ).appendingPathComponent("SKILL.md")
        }

        for sessionIndex in 0..<sessionCount {
            let sessionID = UUID().uuidString.lowercased()
            var lines = [performanceJSONLine(type: "session_meta", payload: [
                "id": sessionID,
                "cwd": root.appendingPathComponent("workspace").path,
                "thread_source": "user"
            ])]
            lines.append(performanceJSONLine(type: "turn_context", payload: [
                "turn_id": "turn-\(sessionIndex)",
                "cwd": root.appendingPathComponent("workspace").path
            ]))
            for readIndex in 0..<readsPerSession {
                let skill = skills[(sessionIndex * readsPerSession + readIndex) % skills.count]
                let callID = "call-\(sessionIndex)-\(readIndex)"
                let arguments = performanceJSONString(["cmd": "cat \(skill.path)"])
                lines.append(performanceJSONLine(type: "response_item", payload: [
                    "type": "function_call",
                    "name": "exec_command",
                    "call_id": callID,
                    "arguments": arguments
                ]))
                let output = performanceJSONString([
                    "exit_code": 0,
                    "output": try String(contentsOf: skill, encoding: .utf8)
                ])
                lines.append(performanceJSONLine(type: "response_item", payload: [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output
                ]))
            }
            try write(
                lines.joined(separator: "\n") + "\n",
                to: sessions.appendingPathComponent("rollout-\(sessionID).jsonl")
            )
        }
        return (root, sessions)
    }

    /// A parser fixture shaped like current Codex history: frequent token and
    /// assistant-message records surround a small number of useful skill reads.
    private func makeNoisyUsageFixture(
        sessionCount: Int,
        irrelevantRecordsPerSession: Int,
        readsPerSession: Int
    ) throws -> (root: URL, sessions: URL) {
        let root = try makeTemporaryRoot(prefix: "metagent-performance-usage-noise")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let workspace = root.appendingPathComponent("workspace")
        let skills = try (0..<10).map { index in
            try writeSkillFixture(
                at: workspace.appendingPathComponent(".agents/skills/noise-skill-\(index)"),
                name: "noise-skill-\(index)",
                description: "Noisy parser fixture \(index)",
                body: String(repeating: "Read this only when its workflow applies.\n", count: 6)
            ).appendingPathComponent("SKILL.md")
        }
        let recordsPerRead = max(1, irrelevantRecordsPerSession / readsPerSession)

        for sessionIndex in 0..<sessionCount {
            let sessionID = UUID().uuidString.lowercased()
            var lines = [performanceJSONLine(type: "session_meta", payload: [
                "id": sessionID,
                "cwd": workspace.path,
                "thread_source": "user"
            ])]
            lines.append(performanceJSONLine(type: "turn_context", payload: [
                "turn_id": "noise-turn-\(sessionIndex)",
                "cwd": workspace.path
            ]))

            var readsAdded = 0
            for recordIndex in 0..<irrelevantRecordsPerSession {
                if recordIndex.isMultiple(of: 2) {
                    lines.append(performanceJSONLine(type: "event_msg", payload: [
                        "type": "token_count",
                        "info": [
                            "input_tokens": 12_000 + recordIndex,
                            "output_tokens": 240,
                            "cached_input_tokens": 8_000
                        ]
                    ]))
                } else {
                    lines.append(performanceJSONLine(type: "response_item", payload: [
                        "type": "message",
                        "role": "assistant",
                        "content": [[
                            "type": "output_text",
                            "text": "Routine progress update \(recordIndex)."
                        ]]
                    ]))
                }

                if readsAdded < readsPerSession,
                   (recordIndex + 1).isMultiple(of: recordsPerRead)
                {
                    let skill = skills[(sessionIndex * readsPerSession + readsAdded) % skills.count]
                    appendSkillRead(
                        skill: skill,
                        callID: "noise-call-\(sessionIndex)-\(readsAdded)",
                        to: &lines
                    )
                    readsAdded += 1
                }
            }

            try write(
                lines.joined(separator: "\n") + "\n",
                to: sessions.appendingPathComponent("rollout-\(sessionID).jsonl")
            )
        }
        return (root, sessions)
    }

    private func appendSkillRead(skill: URL, callID: String, to lines: inout [String]) {
        let arguments = performanceJSONString(["cmd": "cat \(skill.path)"])
        lines.append(performanceJSONLine(type: "response_item", payload: [
            "type": "function_call",
            "name": "exec_command",
            "call_id": callID,
            "arguments": arguments
        ]))
        let output = performanceJSONString([
            "exit_code": 0,
            "output": (try? String(contentsOf: skill, encoding: .utf8)) ?? ""
        ])
        lines.append(performanceJSONLine(type: "response_item", payload: [
            "type": "function_call_output",
            "call_id": callID,
            "output": output
        ]))
    }

    private func performanceJSONLine(type: String, payload: [String: Any]) -> String {
        performanceJSONString([
            "timestamp": "2026-08-01T12:00:00.000Z",
            "type": type,
            "payload": payload
        ])
    }

    private func performanceJSONString(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func seedCompletedUsageSources(_ paths: [String], database: String) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database, &connection), SQLITE_OK)
        let databaseConnection = try XCTUnwrap(connection)
        defer { sqlite3_close(databaseConnection) }
        XCTAssertEqual(sqlite3_exec(databaseConnection, "BEGIN;", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(databaseConnection, """
        INSERT INTO skill_usage_sources (
          path, byte_offset, file_size, modified_at, file_identity,
          prefix_fingerprint, session_id, cwd, turn_id, coverage_started_at,
          pending_events_json, run_session_id, run_session_started_at, run_kind,
          parser_version, updated_at
        ) VALUES (
          ?, 0, 0, ?, ?, '', '', '', '', '', '{}', '', '', 'unknown',
          CAST((SELECT value FROM skill_usage_metadata WHERE key = 'parser_version') AS INTEGER),
          ''
        );
        """, -1, &statement, nil), SQLITE_OK)
        let insert = try XCTUnwrap(statement)
        defer { sqlite3_finalize(insert) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for path in paths {
            let resolvedPath = realpath(path, nil)
            XCTAssertNotNil(resolvedPath)
            let canonicalPath = resolvedPath.map { String(cString: $0) } ?? path
            free(resolvedPath)
            var info = stat()
            XCTAssertEqual(lstat(canonicalPath, &info), 0)
            let modifiedAt = Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            let fileIdentity = "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            sqlite3_bind_text(insert, 1, canonicalPath, -1, transient)
            sqlite3_bind_double(insert, 2, modifiedAt)
            sqlite3_bind_text(insert, 3, fileIdentity, -1, transient)
            XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE)
        }
        XCTAssertEqual(sqlite3_exec(databaseConnection, """
        INSERT INTO skill_usage_metadata (key, value) VALUES
          ('total_files', CAST((SELECT COUNT(*) FROM skill_usage_sources) AS TEXT)),
          ('completed_files', CAST((SELECT COUNT(*) FROM skill_usage_sources) AS TEXT)),
          ('total_bytes', '0'),
          ('processed_bytes', '0'),
          ('is_complete', '1')
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(databaseConnection, "COMMIT;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(databaseConnection, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil),
            SQLITE_OK
        )
    }

    private func usageSourceRowCount(database: String) throws -> Int {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database, &connection), SQLITE_OK)
        let databaseConnection = try XCTUnwrap(connection)
        defer { sqlite3_close(databaseConnection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            databaseConnection,
            "SELECT COUNT(*) FROM skill_usage_sources;",
            -1,
            &statement,
            nil
        ), SQLITE_OK)
        let countStatement = try XCTUnwrap(statement)
        defer { sqlite3_finalize(countStatement) }
        XCTAssertEqual(sqlite3_step(countStatement), SQLITE_ROW)
        return Int(sqlite3_column_int64(countStatement, 0))
    }

    private func writeUsageNoise(minimumBytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let line = performanceJSONLine(type: "event_msg", payload: [
            "type": "token_count",
            "info": ["input_tokens": 12_000, "output_tokens": 240]
        ]) + "\n"
        let repetitions = max(1, 64 * 1_024 / line.utf8.count)
        let chunk = Data(String(repeating: line, count: repetitions).utf8)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written = 0
        while written < minimumBytes {
            try handle.write(contentsOf: chunk)
            written += chunk.count
        }
    }

    private func runGit(_ arguments: [String], in root: URL) throws {
        let result = try runSubprocess(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectory: root,
            timeout: 30
        )
        try XCTSkipUnless(
            result.status == 0,
            "git \(arguments.joined(separator: " ")) failed: \(combinedSubprocessOutput(result))"
        )
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
