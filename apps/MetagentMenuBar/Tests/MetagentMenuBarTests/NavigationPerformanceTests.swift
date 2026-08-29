import Dispatch
import Foundation
import MetagentCore
import Testing
@testable import MetagentMenuBar

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
