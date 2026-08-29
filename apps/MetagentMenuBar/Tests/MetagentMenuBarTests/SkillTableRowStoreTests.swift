import Foundation
import MetagentCore
import Testing
@testable import MetagentMenuBar

@Test func skillTableUsageSignatureIgnoresBackfillProgress() throws {
    let initial = try usageSnapshot(
        processedBytes: 1_024,
        completedFiles: 4,
        lastUpdatedAt: "2026-08-29T10:00:00Z"
    )
    let advanced = try usageSnapshot(
        processedBytes: 8_192,
        completedFiles: 12,
        lastUpdatedAt: "2026-08-29T10:05:00Z"
    )

    #expect(initial != advanced)
    #expect(SkillTableUsageSignature(initial) == SkillTableUsageSignature(advanced))
}

@Test func skillTableUsageSignatureTracksVisibleUsageInputs() throws {
    let initial = try usageSnapshot(summaryInvocations: 1, isBackfillComplete: false)
    let changedSummary = try usageSnapshot(summaryInvocations: 2, isBackfillComplete: false)
    let completed = try usageSnapshot(summaryInvocations: 1, isBackfillComplete: true)

    #expect(SkillTableUsageSignature(initial) != SkillTableUsageSignature(changedSummary))
    #expect(SkillTableUsageSignature(initial) != SkillTableUsageSignature(completed))
}

@MainActor
@Test func usageProgressRefreshesHealthWithoutRebuildingSkillRows() async throws {
    let progressOnly = try usageSnapshot(
        includesSummary: false,
        processedBytes: 8_192,
        completedFiles: 12,
        lastUpdatedAt: "2026-08-29T10:05:00Z"
    )
    let loader = MetagentLaunchCacheLoader(
        loadInventory: { nil },
        loadDeferred: {
            MetagentDeferredLaunchSnapshot(
                usage: progressOnly,
                evaluations: SkillEvaluationSnapshot(),
                modelReleases: .empty,
                releaseAffirmations: [:],
                publications: .empty
            )
        }
    )
    let model = MetagentModel(launchCacheLoader: loader)

    await model.hydrateLaunchCaches()

    #expect(model.usageSnapshot == progressOnly)
    #expect(model.skillTableRevision == 1)
    #expect(model.skillTableRowRevision == 0)
}

@MainActor
@Test func skillTableRowStoreCoalescesAndReusesOneRevision() async {
    let probe = SkillTableBuildProbe()
    let store = SkillTableRowStore { _ in
        await probe.recordBuild()
        return []
    }
    let inputs = emptySkillTableBuildInputs()

    async let first = store.load(revision: 4, inputs: inputs)
    async let second = store.load(revision: 4, inputs: inputs)
    #expect(await first)
    #expect(await second)
    #expect(await store.load(revision: 4, inputs: inputs))
    #expect(await probe.buildCount == 1)
    #expect(store.snapshot?.revision == 4)
}

@MainActor
@Test func skillTableRowStoreRejectsSupersededResults() async {
    let gate = SkillTableBuildGate()
    let store = SkillTableRowStore { inputs in
        if inputs.trackedModelProviders == ["slow"] {
            await gate.wait()
        }
        return []
    }

    let slowLoad = Task { @MainActor in
        await store.load(
            revision: 1,
            inputs: emptySkillTableBuildInputs(trackedModelProviders: ["slow"])
        )
    }
    while !(await gate.hasWaiter) {
        await Task.yield()
    }

    #expect(await store.load(revision: 2, inputs: emptySkillTableBuildInputs()))
    await gate.release()
    #expect(await !slowLoad.value)
    #expect(store.snapshot?.revision == 2)
    #expect(!store.isReady(for: 1))
    #expect(store.isReady(for: 2))
}

@MainActor
@Test func skillTableRowStoreFinishesSharedWorkAfterCallerCancellation() async {
    let gate = SkillTableBuildGate()
    let store = SkillTableRowStore { _ in
        await gate.wait()
        return []
    }
    let load = Task { @MainActor in
        await store.load(revision: 7, inputs: emptySkillTableBuildInputs())
    }
    while !(await gate.hasWaiter) {
        await Task.yield()
    }

    load.cancel()
    await gate.release()
    #expect(await load.value)
    #expect(store.isReady(for: 7))
}

private func emptySkillTableBuildInputs(
    trackedModelProviders: [String] = []
) -> SkillTableBuildInputs {
    SkillTableBuildInputs(
        projects: [],
        usage: .empty,
        evaluations: SkillEvaluationSnapshot(),
        pluginInventoryAvailable: false,
        modelReleases: .empty,
        releaseAffirmations: [:],
        trackedModelProviders: trackedModelProviders
    )
}

private func usageSnapshot(
    summaryInvocations: Int = 1,
    includesSummary: Bool = true,
    isBackfillComplete: Bool = false,
    processedBytes: Int64 = 0,
    completedFiles: Int = 0,
    lastUpdatedAt: String? = nil
) throws -> SkillUsageSnapshot {
    let updatedAt = lastUpdatedAt.map { "\"\($0)\"" } ?? "null"
    let summaries = includesSummary ? """
    [{
      "id": "skill:test",
      "skillName": "test",
      "canonicalPath": "/private/tmp/test/SKILL.md",
      "scope": "global",
      "totalInvocations": \(summaryInvocations),
      "invocations7d": \(summaryInvocations),
      "invocations30d": \(summaryInvocations),
      "activeTurns": \(summaryInvocations),
      "distinctThreads": 1,
      "repeatInvocations": 0,
      "directInvocations": \(summaryInvocations),
      "inferredInvocations": 0,
      "firstUsedAt": "2026-08-29T09:00:00Z",
      "lastUsedAt": "2026-08-29T09:00:00Z"
    }]
    """ : "[]"
    let json = """
    {
      "summaries": \(summaries),
      "totalInvocations": \(includesSummary ? summaryInvocations : 0),
      "totalFiles": 100,
      "completedFiles": \(completedFiles),
      "totalBytes": 10000,
      "processedBytes": \(processedBytes),
      "isBackfillComplete": \(isBackfillComplete),
      "isParserUpgradeBackfill": true,
      "displayParserVersion": 16,
      "targetParserVersion": 17,
      "coverageStartedAt": "2026-08-01T00:00:00Z",
      "lastUpdatedAt": \(updatedAt)
    }
    """
    return try JSONDecoder().decode(SkillUsageSnapshot.self, from: Data(json.utf8))
}

private actor SkillTableBuildProbe {
    private(set) var buildCount = 0

    func recordBuild() {
        buildCount += 1
    }
}

private actor SkillTableBuildGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasWaiter = false

    func wait() async {
        hasWaiter = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
