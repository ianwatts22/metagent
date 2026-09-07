import Foundation
import MetagentCore
import Testing
@testable import MetagentMenuBar

@Test func duplicateAttentionIsOneStableSummary() throws {
    let first = AttentionItem(id: "duplicate:a", fingerprint: "a1", title: "A", detail: "", action: .duplicate("a"))
    let second = AttentionItem(id: "duplicate:b", fingerprint: "b1", title: "B", detail: "", action: .duplicate("b"))
    let summary = try #require(AttentionItem.consolidatingDuplicates([first, second]).first)
    #expect(AttentionItem.consolidatingDuplicates([first, second]).count == 1)
    #expect(summary.title == "2 potential duplicate skills")
    #expect(summary.fingerprint == AttentionItem.consolidatingDuplicates([second, first]).first?.fingerprint)
    #expect(summary.fingerprint != AttentionItem.consolidatingDuplicates([first]).first?.fingerprint)
    if case let .duplicate(groupID) = summary.action { #expect(groupID.isEmpty) }
    else { Issue.record("Summary must open the duplicate overview") }
    #expect(AttentionItem.consolidatingDuplicates([]).isEmpty)
}

@MainActor
@Test func attentionIgnorePersistsAndChangedConditionResurfaces() throws {
    let suite = "AttentionCenterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AttentionCenterStore(defaults: defaults)
    let issue = DoctorIssue(severity: .warning, message: "Projection missing", summary: "Repair projection", projectRoot: "/test/project", guidance: "Create a projection", repairAction: .repairProjection)
    let item = try #require(store.items(doctor: [issue], mcp: MCPHealthSnapshot(), projects: [], scope: nil).first)
    store.ignore(item)
    let reopened = AttentionCenterStore(defaults: defaults)
    #expect(reopened.isIgnored(item))
    var changed = issue
    changed.guidance = "A different repair is needed"
    let changedItem = try #require(reopened.items(doctor: [changed], mcp: MCPHealthSnapshot(), projects: [], scope: nil).first)
    #expect(changedItem.id == item.id)
    #expect(!reopened.isIgnored(changedItem))
    reopened.restore(item)
    #expect(!AttentionCenterStore(defaults: defaults).isIgnored(item))
}

@MainActor
@Test func attentionScopesAndSurfacesUseSameItems() throws {
    let suite = "AttentionCenterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AttentionCenterStore(defaults: defaults)
    let findings = [
        DoctorIssue(severity: .warning, message: "A", projectRoot: "/test/a"),
        DoctorIssue(severity: .warning, message: "B", projectRoot: "/test/b"),
        DoctorIssue(severity: .ok, message: "Healthy", projectRoot: "/test/a")
    ]
    let home = store.items(doctor: findings, mcp: MCPHealthSnapshot(), projects: [], scope: "/test/a")
    let bell = store.items(doctor: findings, mcp: MCPHealthSnapshot(), projects: [], scope: "/test/a")
    #expect(home.map(\.id) == bell.map(\.id))
    #expect(home.map(\.title) == ["A"])
    store.ignore(try #require(home.first))
    #expect(bell.allSatisfy(store.isIgnored))
    #expect(store.items(doctor: findings, mcp: MCPHealthSnapshot(), projects: [], scope: nil).count == 2)
    store.restoreAll()
    #expect(!store.isIgnored(try #require(home.first)))
}

@Test func attentionFingerprintDoesNotConfuseConcatenatedFields() {
    #expect(AttentionItem.fingerprint(["ab", "c"]) != AttentionItem.fingerprint(["a", "bc"]))
    #expect(AttentionItem.fingerprint(["same"]) == AttentionItem.fingerprint(["same"]))
}

@MainActor
@Test func attentionDoctorFindingsWithSameSummaryRemainDistinct() throws {
    let suite = "AttentionCenterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AttentionCenterStore(defaults: defaults)
    let findings = ["/project/.claude/skills", "/project/.codex/skills"].map {
        DoctorIssue(severity: .warning, message: "Invalid projection: \($0)", summary: "Invalid projection", projectRoot: "/project")
    }
    let items = store.items(doctor: findings, mcp: MCPHealthSnapshot(), projects: [], scope: nil)
    #expect(Set(items.map(\.id)).count == 2)
    store.ignore(items[0])
    #expect(!store.isIgnored(items[1]))
}

@MainActor
@Test func attentionMCPProjectScopeExcludesOtherProjectsAndGlobals() throws {
    let suite = "AttentionCenterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AttentionCenterStore(defaults: defaults)
    let snapshot = MCPHealthSnapshot(servers: [
        MCPServerHealth(client: .codex, name: "global", state: .needsSignIn, detail: "Sign in"),
        MCPServerHealth(client: .claude, name: "a", state: .pendingApproval, detail: "Approve", projectStates: [.init(path: "/test/a", state: .pendingApproval)]),
        MCPServerHealth(client: .claude, name: "b", state: .pendingApproval, detail: "Approve", projectStates: [.init(path: "/test/b", state: .pendingApproval)])
    ])
    #expect(store.items(doctor: [], mcp: snapshot, projects: [], scope: nil).count == 3)
    let scoped = store.items(doctor: [], mcp: snapshot, projects: [], scope: "/test/a")
    #expect(scoped.map(\.id) == ["mcp:claude:a"])
}

private actor AttentionBuildCounter {
    var calls = 0
    func record() -> [SkillOverlapGroup] { calls += 1; return [] }
}

@MainActor
@Test func attentionOverlapBuildsCoalesceAndRescanOnInventoryRevision() async throws {
    let suite = "AttentionCenterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let counter = AttentionBuildCounter()
    let store = AttentionCenterStore(defaults: defaults, buildOverlaps: { _ in await counter.record() })
    await store.refreshOverlaps(projects: [], revision: 1)
    await store.refreshOverlaps(projects: [], revision: 1)
    #expect(await counter.calls == 1)
    await store.refreshOverlaps(projects: [], revision: 2)
    #expect(await counter.calls == 2)
}
