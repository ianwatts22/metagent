import Dispatch
import Darwin
import Foundation
import MetagentCore
import Testing
import XCTest
@testable import MetagentMenuBar

@Test func projectRowsCannotIntroduceRootsOutsideTheSharedInventory() {
    let root = "/private/tmp/mcp-only-project"
    let excluded = "/private/tmp/custom-worktree"
    let project = ProjectStatus.previewFixture(project: SkillProject(
        root: root, skillsDir: root + "/.agents/skills", validSkills: [], skills: []))
    let health = MCPHealthSnapshot(servers: [MCPServerHealth(
        client: .claude, name: "demo", state: .pendingApproval, detail: "",
        projectStates: [MCPProjectState(path: root, state: .pendingApproval),
                        MCPProjectState(path: excluded, state: .pendingApproval)])])
    let issues = [DoctorIssue(severity: .warning, message: "Old finding", projectRoot: excluded)]
    let rows = ProjectDirectoryRow.rows(projects: [project], mcpHealth: health,
        doctorIssues: issues, codebaseSizes: [:], selectedProjectRoot: nil)
    #expect(rows.map(\.root) == [root])
    #expect(rows.first?.skillCount == 0)
    #expect(rows.first?.mcpCount == 1)
    #expect(directoryFilterOptions(projects: [project]).map(\.root) == [root])
}

@Test func indexedProjectRowsPreserveDirectoryCountsAndAttention() throws {
    let root = "/private/tmp/metagent-project-row-\(UUID().uuidString)"
    let skillPath = root + "/.agents/skills/shared"
    let project = ProjectStatus.previewFixture(project: SkillProject(
        root: root,
        skillsDir: root + "/.agents/skills",
        validSkills: ["shared"],
        skills: [navigationSkill(path: skillPath)]
    ))
    let mcpHealth = MCPHealthSnapshot(servers: [
        MCPServerHealth(
            client: .codex,
            name: "example",
            state: .pendingApproval,
            detail: "Approval required",
            projectStates: [MCPProjectState(path: root, state: .pendingApproval)]
        ),
        MCPServerHealth(
            client: .claude,
            name: "example",
            state: .configured,
            detail: "Configured",
            projectStates: [MCPProjectState(path: root, state: .configured)]
        ),
    ])
    let issues = [DoctorIssue(
        severity: .warning,
        message: "Projection needs repair",
        projectRoot: root,
        category: .projection
    )]

    let row = try #require(ProjectDirectoryRow.rows(
        projects: [project],
        mcpHealth: mcpHealth,
        doctorIssues: issues,
        codebaseSizes: [:],
        selectedProjectRoot: nil
    ).first)

    #expect(row.root == root)
    #expect(row.skillCount == 1)
    // Two client records for one named MCP remain one logical server.
    #expect(row.mcpCount == 1)
    #expect(row.claudeState == .missing)
    #expect(row.issueCount == 1)
}

@Test func projectDirectoryRowsResolveEachPathOncePerBuild() throws {
    let root = "/private/tmp/metagent-project-path-cache"
    let firstPath = root + "/.agents/skills/first"
    let secondPath = root + "/.agents/skills/second"
    var first = navigationSkill(path: firstPath)
    first.name = "same-name"
    var second = navigationSkill(path: secondPath)
    second.name = "same-name"
    var projection = first
    projection.location = "claude"
    projection.path = root + "/.claude/skills/first"
    projection.representation = "projection"
    let project = ProjectStatus.previewFixture(project: SkillProject(
        root: root,
        skillsDir: root + "/.agents/skills",
        validSkills: ["same-name"],
        skills: [first, second, projection]
    ))
    let issue = DoctorIssue(severity: .warning, message: "Review", projectRoot: root)
    var resolutions: [String: Int] = [:]
    var canonicalizer = SkillPathCanonicalizer { path in
        resolutions[path, default: 0] += 1
        return path
    }
    let row = try #require(ProjectDirectoryRow.rows(
        projects: [project, project],
        mcpHealth: MCPHealthSnapshot(),
        doctorIssues: [issue, issue],
        codebaseSizes: [:],
        selectedProjectRoot: root,
        canonicalizer: &canonicalizer
    ).first)

    #expect(row.skillCount == 2) // Independent same-named bundles stay distinct.
    #expect(row.issueCount == 1)
    #expect(resolutions == [root: 1, firstPath: 1, secondPath: 1, NSHomeDirectory(): 1])
}

@Test func projectDirectoryRowsRereadRetargetedSkillAndClaudeLinks() throws {
    let fixtureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("metagent-project-link-freshness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let projectRoot = fixtureRoot.appendingPathComponent("project", isDirectory: true)
    let skillsRoot = projectRoot.appendingPathComponent(".agents/skills", isDirectory: true)
    let claudeRoot = projectRoot.appendingPathComponent(".claude", isDirectory: true)
    let firstBundle = fixtureRoot.appendingPathComponent("bundles/a", isDirectory: true)
    let secondBundle = fixtureRoot.appendingPathComponent("bundles/b", isDirectory: true)
    for directory in [skillsRoot, claudeRoot, firstBundle, secondBundle] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let skillLink = skillsRoot.appendingPathComponent("shared")
    let claudeLink = claudeRoot.appendingPathComponent("skills")
    try FileManager.default.createSymbolicLink(at: skillLink, withDestinationURL: firstBundle)
    try FileManager.default.createSymbolicLink(at: claudeLink, withDestinationURL: skillsRoot)
    let shared = navigationSkill(path: skillLink.path)
    var independent = navigationSkill(path: firstBundle.path)
    independent.location = "codex"
    let project = ProjectStatus.previewFixture(project: SkillProject(
        root: projectRoot.path,
        skillsDir: skillsRoot.path,
        validSkills: ["shared"],
        skills: [shared, independent]
    ))
    func build() -> [ProjectDirectoryRow] {
        ProjectDirectoryRow.rows(
            projects: [project],
            mcpHealth: MCPHealthSnapshot(),
            doctorIssues: [],
            codebaseSizes: [:],
            selectedProjectRoot: nil
        )
    }
    let before = try #require(build().first)
    #expect(before.skillCount == 1)
    #expect(before.codexOnlyCount == 0)
    #expect(before.claudeState == .healthy)

    // The skill destinations have the same byte length. Freshness cannot rely on
    // bundle metadata, changed input arrays, or a persistent path cache.
    try FileManager.default.removeItem(at: skillLink)
    try FileManager.default.createSymbolicLink(at: skillLink, withDestinationURL: secondBundle)
    try FileManager.default.removeItem(at: claudeLink)
    try FileManager.default.createSymbolicLink(at: claudeLink, withDestinationURL: secondBundle)
    let after = try #require(build().first)
    #expect(after.skillCount == 2)
    #expect(after.codexOnlyCount == 1)
    #expect(after.claudeState == .wrong)
    // The captured inventory input was not replaced between builds.
    #expect(shared.canonicalPath == skillLink.path)
}

@Test func projectDirectoryRowsPreserveEmptyPathIdentitiesAndProjectionExclusions() throws {
    let root = "/private/tmp/metagent-project-empty-paths"
    var agents = navigationSkill(path: root + "/.agents/skills/shared")
    agents.canonicalPath = ""
    var codex = agents
    codex.location = "codex"
    codex.path = root + "/.codex/skills/shared"
    codex.authority = "codex-system"
    var claude = agents
    claude.location = "claude"
    claude.path = root + "/.claude/skills/shared"
    claude.representation = "projection"
    let project = ProjectStatus.previewFixture(project: SkillProject(
        root: root,
        skillsDir: root + "/.agents/skills",
        validSkills: ["shared"],
        skills: [agents, codex, claude]
    ))
    let row = try #require(ProjectDirectoryRow.rows(
        projects: [project],
        mcpHealth: MCPHealthSnapshot(),
        doctorIssues: [],
        codebaseSizes: [:],
        selectedProjectRoot: nil
    ).first)
    #expect(row.skillCount == 3) // Empty identities remain name + location.
    #expect(row.codexOnlyCount == 0) // System inventory isn't a private install.
    #expect(row.claudeOnlyCount == 0) // Projection isn't a private install.
}

@Test func projectDirectoryScopeTracksRetargetedRootAliases() throws {
    let fixtureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("metagent-project-scope-freshness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let firstRoot = fixtureRoot.appendingPathComponent("first", isDirectory: true)
    let secondRoot = fixtureRoot.appendingPathComponent("second", isDirectory: true)
    for directory in [firstRoot, secondRoot] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let firstRootKey = standardizedDirectoryPath(firstRoot.path)
    let secondRootKey = standardizedDirectoryPath(secondRoot.path)
    let alias = fixtureRoot.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstRoot)
    let projects = [alias, firstRoot].map { root in
        ProjectStatus.previewFixture(project: SkillProject(
            root: root.path,
            skillsDir: root.appendingPathComponent(".agents/skills").path,
            validSkills: [],
            skills: []
        ))
    }
    func build(selectedRoot: String?) -> [ProjectDirectoryRow] {
        ProjectDirectoryRow.rows(
            projects: projects,
            mcpHealth: MCPHealthSnapshot(),
            doctorIssues: [],
            codebaseSizes: [:],
            selectedProjectRoot: selectedRoot
        )
    }
    #expect(build(selectedRoot: nil).map(\.root) == [firstRootKey])
    #expect(build(selectedRoot: alias.path).map(\.root) == [firstRootKey])
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: secondRoot)
    #expect(Set(build(selectedRoot: nil).map(\.root)) == [firstRootKey, secondRootKey])
    #expect(build(selectedRoot: alias.path).map(\.root) == [secondRootKey])
}

@Test func skillTableInitialSortUsesEverySelectedViewDefault() {
    let defaults: [(SkillTableView, [KeyPathComparator<SkillTableRow>])] = [
        (.summary, [KeyPathComparator(\SkillTableRow.invocations30d, order: .reverse)]),
        (.review, [KeyPathComparator(\SkillTableRow.metagentScoreSortValue)]),
        (.duplicates, [KeyPathComparator(\SkillTableRow.overlapSortValue), KeyPathComparator(\SkillTableRow.skillName)]),
        (.published, [KeyPathComparator(\SkillTableRow.skillName)]),
        (.inventory, [KeyPathComparator(\SkillTableRow.skillName)]),
        (.usage, [KeyPathComparator(\SkillTableRow.totalInvocations, order: .reverse)]),
    ]
    for (view, expected) in defaults {
        #expect(skillTableSortOrder(for: view, requested: nil) == expected)
        #expect(skillTableSortOrder(for: view) == expected)
    }
    let unknownView = SkillTableView(rawValue: "future-unsupported-view") ?? .summary
    #expect(skillTableSortOrder(for: unknownView) == defaults[0].1)
}

@Test func skillTableRequestedSortSurvivesDefaultsAndCanBeCleared() {
    let custom = [
        KeyPathComparator(\SkillTableRow.projectName, order: .reverse),
        KeyPathComparator(\SkillTableRow.skillName),
    ]
    for view in SkillTableView.allCases {
        #expect(skillTableSortOrder(for: view, requested: custom) == custom)
        #expect(skillTableSortOrder(for: view, requested: []) == [])
        // The existing onAppear/view-change reset still requests the default;
        // it must not persist a previous view's explicit sort.
        #expect(skillTableSortOrder(for: view, requested: skillTableSortOrder(for: view))
            == skillTableSortOrder(for: view))
    }
}

/// Guards the indexing strategy that replaced one full project-array scan per
/// displayed directory. Live Accessibility timing remains the navigation
/// authority; this proxy keeps the data preparation from becoming quadratic.
@Test func projectRowIndexPerformanceProxy() {
    guard ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_TESTS"] == "1" else { return }
    let projects = (0..<200).map { index in
        ProjectStatus.previewFixture(project: SkillProject(
            root: "/private/tmp/metagent-project-\(index)",
            skillsDir: "/private/tmp/metagent-project-\(index)/.agents/skills",
            validSkills: [],
            skills: []
        ))
    }
    let roots = projects.map(\.root)
    let iterations = 3

    let legacy = navigationBenchmark(iterations: iterations) {
        roots.reduce(into: 0) { count, root in
            count += projects.filter {
                standardizedDirectoryPath($0.root) == standardizedDirectoryPath(root)
            }.count
        }
    }
    let current = navigationBenchmark(iterations: iterations) {
        let projectsByRoot = projectStatusesByCanonicalRoot(projects)
        return roots.reduce(into: 0) { count, root in
            count += projectsByRoot[standardizedDirectoryPath(root)]?.count ?? 0
        }
    }

    print("Projects row-index proxy: legacy=\(legacy.elapsedMilliseconds)ms current=\(current.elapsedMilliseconds)ms")
    #expect(current.checksum == legacy.checksum)
    #expect(current.elapsedMilliseconds < legacy.elapsedMilliseconds * 0.25)
}

/// Full Projects row preparation, including filesystem canonicalization and
/// Claude-link evidence. This is a component benchmark, not rendered latency.
final class NavigationComponentPerformanceTests: XCTestCase {
    func testProjectDirectoryRowsPerformance() throws {
        try measureProjectRows(projectionHeavy: true)
    }

    func testOrdinaryProjectDirectoryRowsPerformance() throws {
        try measureProjectRows(projectionHeavy: false)
    }

    /// Replicates the four stages in the detached Skills builder with one
    /// build-local canonicalizer. This excludes its scheduling and SwiftUI.
    func testSkillsRowStageProfile() throws {
        guard ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_TESTS"] == "1" else { return }
        let fixture = try ProjectRowPerformanceFixture(projectionHeavy: false)
        defer { fixture.remove() }
        try fixture.writeComparableBundles()
        let iterations = min(20, max(1, Int(
            ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_ITERATIONS"] ?? "5"
        ) ?? 5))
        for iteration in 0..<iterations {
            var canonicalizer = SkillPathCanonicalizer()
            let inventory = navigationStage {
                InventorySkillRow.rows(
                    from: fixture.projects,
                    usage: .empty,
                    evaluations: SkillEvaluationSnapshot(),
                    canonicalizer: &canonicalizer
                )
            }
            let overlaps = navigationStage {
                MetagentCore.detectSkillOverlaps(inventory.value.map { $0.skill })
            }
            let usage = navigationStage {
                UsageSkillRow.rows(
                    projects: fixture.projects,
                    summaries: [],
                    isBackfillComplete: false,
                    canonicalizer: &canonicalizer
                )
            }
            let merged = navigationStage {
                SkillTableRow.rows(
                    inventoryRows: inventory.value,
                    usageRows: usage.value,
                    projectRoots: fixture.projects.map(\.root),
                    pluginInventoryAvailable: false,
                    isBackfillComplete: false,
                    overlaps: overlaps.value,
                    canonicalizer: &canonicalizer
                )
            }
            XCTAssertEqual(inventory.value.count, 360)
            XCTAssertEqual(overlaps.value.count, 15)
            XCTAssertEqual(merged.value.count, 360)
            print("[Skills synthetic stages] iteration=\(iteration + 1) "
                + "inventory=\(inventory.summary) overlaps=\(overlaps.summary) "
                + "usage=\(usage.summary) merged=\(merged.summary)")
        }
    }

    private func measureProjectRows(projectionHeavy: Bool) throws {
        guard ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_TESTS"] == "1" else { return }
        let fixture = try ProjectRowPerformanceFixture(projectionHeavy: projectionHeavy)
        defer { fixture.remove() }
        let options = XCTMeasureOptions()
        let iterations = Int(ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_ITERATIONS"] ?? "5") ?? 5
        options.iterationCount = min(20, max(1, iterations))
        var lastRows: [ProjectDirectoryRow] = []
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            lastRows = ProjectDirectoryRow.rows(
                projects: fixture.projects,
                mcpHealth: MCPHealthSnapshot(),
                doctorIssues: [],
                codebaseSizes: [:],
                selectedProjectRoot: nil
            )
        }
        XCTAssertEqual(lastRows.count, 24)
        XCTAssertEqual(lastRows.reduce(0) { $0 + $1.skillCount }, projectionHeavy ? 144 : 360)
        XCTAssertTrue(lastRows.allSatisfy { $0.claudeState == .healthy })
    }
}

private struct ProjectRowPerformanceFixture {
    let root: URL
    let projects: [ProjectStatus]

    init(projectionHeavy: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-project-rows-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        var projects: [ProjectStatus] = []
        do {
            for projectIndex in 0..<24 {
                let projectRoot = root.appendingPathComponent("projects/project-\(projectIndex)", isDirectory: true)
                let skillsRoot = projectRoot.appendingPathComponent(".agents/skills", isDirectory: true)
                let claudeRoot = projectRoot.appendingPathComponent(".claude", isDirectory: true)
                try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    at: claudeRoot.appendingPathComponent("skills"),
                    withDestinationURL: skillsRoot
                )
                var skills: [SkillInventoryItem] = []
                let skillsPerProject = projectionHeavy ? 6 : 15
                for skillIndex in 0..<skillsPerProject {
                    let name = "skill-\(skillIndex)"
                    let skillRoot = skillsRoot.appendingPathComponent(name, isDirectory: true)
                    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
                    // The ordinary shape has 450 representations of 360 IDs
                    // (1.25x); the projection-heavy shape has 432 of 144 (3x).
                    let locations = projectionHeavy
                        ? ["agents", "codex", "claude"]
                        : ((projectIndex * skillsPerProject + skillIndex) % 4 == 0
                            ? ["agents", "claude"] : ["agents"])
                    for location in locations {
                        var skill = navigationSkill(path: skillRoot.path)
                        skill.name = name
                        skill.location = location
                        skill.path = projectRoot.appendingPathComponent(".\(location)/skills/\(name)").path
                        skill.canonicalPath = skillRoot.path
                        skill.representation = location == "agents" ? "canonical" : "projection"
                        skills.append(skill)
                    }
                }
                projects.append(ProjectStatus.previewFixture(project: SkillProject(
                    root: projectRoot.path,
                    skillsDir: skillsRoot.path,
                    validSkills: (0..<skillsPerProject).map { "skill-\($0)" },
                    skills: skills
                )))
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        self.projects = projects
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeComparableBundles() throws {
        for path in Set(projects.flatMap(\.skills).map(\.canonicalPath)) {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let name = directory.lastPathComponent
            let skill = """
            ---
            name: \(name)
            description: Deterministic staged row preparation fixture
            ---
            # \(name)

            \(String(repeating: "Read current evidence and preserve source identity.\n", count: 40))
            """
            let references = directory.appendingPathComponent("references", isDirectory: true)
            let scripts = directory.appendingPathComponent("scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            try Data(skill.utf8).write(to: directory.appendingPathComponent("SKILL.md"))
            try Data(String(repeating: "Reference evidence for a bounded task.\n", count: 30).utf8)
                .write(to: references.appendingPathComponent("notes.md"))
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: scripts.appendingPathComponent("check.sh"))
        }
    }
}

private struct NavigationStage<Value> {
    let value: Value
    let elapsedMilliseconds: Double
    let cpuMilliseconds: Double

    var summary: String {
        String(format: "%.3fms_wall/%.3fms_cpu", elapsedMilliseconds, cpuMilliseconds)
    }
}

private func navigationStage<Value>(operation: () -> Value) -> NavigationStage<Value> {
    func cpuTime() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    let started = DispatchTime.now().uptimeNanoseconds
    let cpuStarted = cpuTime()
    let value = operation()
    let cpuElapsed = cpuTime() - cpuStarted
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    return NavigationStage(
        value: value,
        elapsedMilliseconds: Double(elapsed) / 1_000_000,
        cpuMilliseconds: cpuElapsed * 1_000
    )
}

private func navigationBenchmark(
    iterations: Int,
    operation: () -> Int
) -> (elapsedMilliseconds: Double, checksum: Int) {
    let started = DispatchTime.now().uptimeNanoseconds
    var checksum = 0
    for _ in 0..<iterations {
        checksum += operation()
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    return (Double(elapsed) / 1_000_000, checksum)
}

private func navigationSkill(path: String) -> SkillInventoryItem {
    SkillInventoryItem(
        name: "shared",
        description: "Shared test skill",
        path: path,
        location: "agents",
        locationLabel: "Shared",
        originKind: "installed",
        scope: "project",
        manager: "local",
        authority: "user",
        mutability: "editable",
        representation: "canonical",
        canonicalPath: path,
        source: nil,
        sourceType: nil,
        sourceURL: nil,
        ref: nil,
        installedAt: nil,
        updatedAt: nil,
        symlinkedContainer: false,
        folderKind: "project",
        characterCount: 100,
        wordCount: 20,
        tokenEstimate: 25,
        skillFileCharacterCount: 100,
        skillFileWordCount: 20,
        skillFileTokenEstimate: 25,
        textFileCount: 1,
        referenceFileCount: 0,
        scriptFileCount: 0,
        assetFileCount: 0,
        otherFileCount: 0,
        otherFolderCount: 0,
        hasOpenAIYaml: false,
        hasIconSmall: false,
        hasIconLarge: false,
        hasIconAndLogo: false,
        iconSmallPath: nil,
        iconLargePath: nil
    )
}
