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

private func filter(
    view: SkillTableView,
    selectedRoot: String? = nil,
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
