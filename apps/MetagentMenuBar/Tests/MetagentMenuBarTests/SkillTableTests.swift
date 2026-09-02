import Dispatch
import Foundation
import MetagentCore
import Testing
@testable import MetagentMenuBar

@Test func skillTableFilterPreservesViewScopeUsageSourceAndSearchSemantics() {
    let global = skillTableRow(name: "global-helper", root: NSHomeDirectory(), scope: "global")
    let project = skillTableRow(name: "project-helper", root: "/tmp/project-a", scope: "project")
    let historical = historicalSkillTableRow(name: "old-helper", scope: "global")

    #expect(filter(view: .summary).apply(to: [global, project, historical]).map(\.skillName) == [
        "global-helper", "project-helper",
    ])
    #expect(filter(view: .usage).apply(to: [global, project, historical]).map(\.skillName) == [
        "global-helper", "project-helper", "old-helper",
    ])
    #expect(filter(view: .summary, selectedRoot: NSHomeDirectory()).apply(to: [global, project])
        .map(\.skillName) == ["global-helper"])
    #expect(filter(view: .summary, selectedRoot: "/tmp/project-a").apply(to: [global, project])
        .map(\.skillName) == ["project-helper"])
    #expect(filter(view: .summary, scope: .project).apply(to: [global, project])
        .map(\.skillName) == ["project-helper"])
    #expect(filter(view: .summary, usage: .observed).apply(to: [global, project]).isEmpty)
    #expect(filter(view: .summary, query: "PROJECT-HELPER").apply(to: [global, project])
        .map(\.skillName) == ["project-helper"])
    #expect(filter(view: .summary, hiddenSources: [.local]).apply(to: [global, project]).isEmpty)
}

@Test func skillTableFilterPreservesDuplicateAndRemovalSemantics() throws {
    let overlap = SkillOverlapMembership(
        groupID: "duplicate:test",
        kind: .sameName,
        similarity: 0.5,
        suggestedRemoval: false
    )
    let duplicate = skillTableRow(
        name: "duplicate",
        root: "/tmp/project-a",
        scope: "project",
        overlap: overlap
    )
    let ordinary = skillTableRow(name: "ordinary", root: "/tmp/project-a", scope: "project")

    #expect(filter(view: .duplicates).apply(to: [duplicate, ordinary]).map(\.skillName) == ["duplicate"])

    let removalID = try #require(duplicate.inventory?.removalRequest?.id)
    #expect(filter(view: .summary, pendingRemovalIDs: [removalID]).apply(to: [duplicate]).isEmpty)
    #expect(filter(view: .summary, completedRemovalIDs: [removalID]).apply(to: [duplicate]).isEmpty)
}

@Test func duplicateRecommendationPreselectsOnlySafeSuggestedRemovals() throws {
    let keptOverlap = SkillOverlapMembership(
        groupID: "duplicate:recommendation",
        kind: .globalProject,
        similarity: 1,
        suggestedRemoval: false
    )
    let removedOverlap = SkillOverlapMembership(
        groupID: "duplicate:recommendation",
        kind: .globalProject,
        similarity: 1,
        suggestedRemoval: true
    )
    let kept = skillTableRow(
        name: "shared-skill",
        root: NSHomeDirectory(),
        scope: "global",
        overlap: keptOverlap
    )
    let removed = skillTableRow(
        name: "shared-skill",
        root: "/tmp/project-a",
        scope: "project",
        overlap: removedOverlap
    )
    let group = DuplicateReviewGroup(
        id: "duplicate:recommendation",
        kind: .globalProject,
        similarity: 1,
        rows: [kept, removed]
    )

    #expect(recommendedRemovalIDs(for: group) == [removed.id])
    #expect(skillRemovalMessage(for: [try #require(removed.inventory)]).isEmpty)

    let nearRemoved = skillTableRow(
        name: "shared-skill",
        root: "/tmp/project-b",
        scope: "project",
        overlap: SkillOverlapMembership(
            groupID: "duplicate:near-match",
            kind: .globalProject,
            similarity: 0.98,
            suggestedRemoval: false
        )
    )
    let nearMatch = DuplicateReviewGroup(
        id: "duplicate:near-match",
        kind: .globalProject,
        similarity: 0.98,
        rows: [kept, nearRemoved]
    )
    #expect(recommendedRemovalIDs(for: nearMatch).isEmpty)
}

@Test func skillTablePresentationPreservesFlatGroupingSortingAndSelectionSemantics() throws {
    let projectBeta = skillTableRow(name: "beta", root: "/tmp/project-b", scope: "project")
    let globalAlpha = skillTableRow(name: "alpha", root: NSHomeDirectory(), scope: "global")
    let candidates = [projectBeta, globalAlpha]
    let sortOrder = [KeyPathComparator(\SkillTableRow.skillName)]

    let flat = SkillTablePresentation(
        candidates: candidates,
        filter: filter(view: .summary),
        grouping: .none,
        sortOrder: sortOrder
    )
    #expect(!flat.usesHierarchy)
    #expect(flat.rows.map(\.skillName) == ["beta", "alpha"])
    #expect(flat.displayRows.map(\.skillName) == ["alpha", "beta"])
    #expect(flat.resolvedRows(for: []).isEmpty)
    #expect(flat.resolvedRows(for: [globalAlpha.id]).map(\.skillName) == ["alpha"])

    let grouped = SkillTablePresentation(
        candidates: candidates,
        filter: filter(view: .summary),
        grouping: .location,
        sortOrder: sortOrder
    )
    #expect(grouped.usesHierarchy)
    #expect(Set(grouped.displayRows.map(\.skillName)) == ["Global", "project-b"])
    let projectGroup = try #require(grouped.displayRows.first { $0.skillName == "project-b" })
    #expect(grouped.resolvedRows(for: [projectGroup.id]).map(\.skillName) == ["beta"])
    #expect(grouped.resolvedRows(for: [projectBeta.id]).map(\.skillName) == ["beta"])
}

@Test func skillTableBuildCanonicalizesEachRawPathOnceAndHotPathsStayPure() throws {
    let fixture = skillTableRow(name: "shared-helper", root: "/alias/work", scope: "project")
    let project = try #require(fixture.inventory?.project)
    let realRoot = "/real/work"
    let realSkill = realRoot + "/.agents/skills/shared-helper"
    let aliases = [
        project.root: realRoot,
        project.skills[0].path: realSkill,
    ]
    var resolutionCounts: [String: Int] = [:]
    var canonicalizer = SkillPathCanonicalizer { path in
        resolutionCounts[path, default: 0] += 1
        return aliases[path] ?? URL(fileURLWithPath: path).standardizedFileURL.path
    }

    let inventoryRows = InventorySkillRow.rows(
        from: [project],
        usage: .empty,
        evaluations: SkillEvaluationSnapshot(),
        canonicalizer: &canonicalizer
    )
    let usageRows = UsageSkillRow.rows(
        projects: [project],
        summaries: [],
        isBackfillComplete: true,
        canonicalizer: &canonicalizer
    )
    let rows = SkillTableRow.rows(
        inventoryRows: inventoryRows,
        usageRows: usageRows,
        projectRoots: [project.root],
        pluginInventoryAvailable: true,
        isBackfillComplete: true,
        overlaps: [],
        canonicalizer: &canonicalizer
    )

    #expect(resolutionCounts == [project.root: 1, project.skills[0].path: 1])
    let countsAfterBuild = resolutionCounts
    let row = try #require(rows.first)
    let tableFilter = filter(
        view: .summary,
        selectedRoot: project.root,
        selectedRootKey: realRoot,
        query: "SHARED"
    )
    for _ in 0..<20 {
        _ = row.id
        _ = row.inventory?.id
        _ = row.canonicalPathKey
        _ = row.projectRootKey
        _ = tableFilter.includes(row)
        _ = SkillGrouping.location.key(for: row)
        _ = [row].sorted(using: [KeyPathComparator(\SkillTableRow.skillName)])
    }
    #expect(resolutionCounts == countsAfterBuild)
}

@Test func skillTableHistoricalRootInferenceUsesCanonicalLongestPrefix() throws {
    let usage = UsageSkillRow.placeholder(
        id: "historical:nested",
        skillName: "nested",
        canonicalPath: "/alias/work/nested/.agents/skills/nested",
        scope: "project",
        status: .neverObserved
    )
    let aliases = [
        "/alias/work": "/real/work",
        "/alias/work/nested": "/real/work/nested",
        "/alias/work/nested/.agents/skills/nested": "/real/work/nested/.agents/skills/nested",
    ]
    var canonicalizer = SkillPathCanonicalizer { aliases[$0] ?? $0 }
    let rows = SkillTableRow.rows(
        inventoryRows: [],
        usageRows: [usage],
        projectRoots: ["/alias/work", "/alias/work/nested"],
        pluginInventoryAvailable: true,
        isBackfillComplete: true,
        overlaps: [],
        canonicalizer: &canonicalizer
    )
    let row = try #require(rows.first)

    #expect(row.projectRoot == "/real/work/nested")
    #expect(row.projectRootKey == "/real/work/nested")
    #expect(filter(
        view: .usage,
        selectedRoot: "/alias/work/nested",
        selectedRootKey: "/real/work/nested"
    ).includes(row))
}

/// Reproduces the row-pipeline work the old `InventorySection.body` performed
/// independently for its count, empty state, selection, and table. This is a
/// deliberately narrow proxy: live profiling remains the authority for
/// SwiftUI/AttributeGraph allocations.
@Test func skillTablePresentationPerformanceProxy() {
    guard ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_TESTS"] == "1" else { return }
    let candidates = (0..<600).map { index in
        historicalSkillTableRow(name: "skill-\(600 - index)", scope: "global")
    }
    let tableFilter = filter(view: .usage)
    let sortOrder = [KeyPathComparator(\SkillTableRow.skillName)]
    let iterations = 200

    let legacy = benchmark(iterations: iterations) {
        let wideCountRows = tableFilter.apply(to: candidates).sorted(using: sortOrder)
        let narrowCountRows = tableFilter.apply(to: candidates).sorted(using: sortOrder)
        let emptyRows = tableFilter.apply(to: candidates)
        let selectedRows = tableFilter.apply(to: candidates).sorted(using: sortOrder)
        let tableRows = tableFilter.apply(to: candidates).sorted(using: sortOrder)
        return wideCountRows.count
            + narrowCountRows.count
            + emptyRows.count
            + selectedRows.count
            + tableRows.count
    }
    let current = benchmark(iterations: iterations) {
        let presentation = SkillTablePresentation(
            candidates: candidates,
            filter: tableFilter,
            grouping: .none,
            sortOrder: sortOrder
        )
        return presentation.rows.count + presentation.displayRows.count * 4
    }

    print("Skills row-pipeline proxy: legacy=\(legacy.elapsedMilliseconds)ms current=\(current.elapsedMilliseconds)ms")
    #expect(legacy.checksum == current.checksum)
    #expect(current.elapsedMilliseconds < legacy.elapsedMilliseconds * 0.75)
}

private func benchmark(iterations: Int, operation: () -> Int) -> (elapsedMilliseconds: Double, checksum: Int) {
    let started = DispatchTime.now().uptimeNanoseconds
    var checksum = 0
    for _ in 0..<iterations {
        checksum += operation()
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    return (Double(elapsed) / 1_000_000, checksum)
}

private func filter(
    view: SkillTableView,
    selectedRoot: String? = nil,
    selectedRootKey: String? = nil,
    hiddenSources: Set<SkillSourceCategory> = [],
    scope: SkillScopeFilter = .all,
    usage: UsageFilter = .all,
    query: String = "",
    pendingRemovalIDs: Set<String> = [],
    completedRemovalIDs: Set<String> = []
) -> SkillTableFilter {
    SkillTableFilter(
        selectedView: view,
        selectedProjectRoot: selectedRoot,
        selectedProjectRootKey: selectedRootKey,
        hiddenSources: hiddenSources,
        scope: scope,
        usage: usage,
        query: query,
        pendingRemovalIDs: pendingRemovalIDs,
        completedRemovalIDs: completedRemovalIDs
    )
}

private func historicalSkillTableRow(name: String, scope: String) -> SkillTableRow {
    SkillTableRow(
        inventory: nil,
        usage: .placeholder(
            id: "historical:\(name)",
            skillName: name,
            canonicalPath: nil,
            scope: scope,
            status: .neverObserved
        ),
        historicalProjectRoot: nil,
        pluginInventoryAvailable: true
    )
}

private func skillTableRow(
    name: String,
    root: String,
    scope: String,
    overlap: SkillOverlapMembership? = nil
) -> SkillTableRow {
    let path = root + "/.agents/skills/" + name
    let skill = SkillInventoryItem(
        name: name,
        description: "Test skill",
        path: path,
        location: "agents",
        locationLabel: "Shared",
        originKind: "installed",
        scope: scope,
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
        folderKind: scope == "global" ? "home" : "project",
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
    let project = ProjectStatus.previewFixture(project: SkillProject(
        root: root,
        skillsDir: root + "/.agents/skills",
        validSkills: [name],
        skills: [skill]
    ))
    let inventory = InventorySkillRow(
        project: project,
        skill: project.skills[0],
        variants: project.skills,
        metagentScore: MetagentSkillScore(score: 80, confidence: .medium, components: []),
        pluginEval: nil,
        codexReview: nil,
        pluginEvalIsStale: false,
        codexReviewIsStale: false
    )
    return SkillTableRow(
        inventory: inventory,
        usage: .inventoryPlaceholder(
            id: "inventory:\(name)",
            skillName: name,
            canonicalPath: path,
            folderKind: skill.folderKind,
            projectRoot: root,
            isBackfillComplete: true
        ),
        historicalProjectRoot: nil,
        pluginInventoryAvailable: true,
        overlap: overlap
    )
}
