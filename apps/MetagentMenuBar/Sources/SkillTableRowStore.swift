import Foundation
import MetagentCore
import SwiftUI

/// The only usage fields that can change Skills table rows. Backfill progress
/// still publishes through `usageSnapshot`, but must not cancel and restart an
/// expensive row build when its visible inputs are unchanged.
struct SkillTableUsageSignature: Sendable, Equatable {
    let summaries: [SkillUsageSummary]
    let isBackfillComplete: Bool

    init(_ snapshot: SkillUsageSnapshot) {
        summaries = snapshot.summaries
        isBackfillComplete = snapshot.isBackfillComplete
    }
}

struct SkillTableBuildInputs: Sendable {
    let projects: [ProjectStatus]
    let usage: SkillUsageSnapshot
    let evaluations: SkillEvaluationSnapshot
    let pluginInventoryAvailable: Bool
    let modelReleases: ModelReleaseSnapshot
    let releaseAffirmations: [String: Date]
    let trackedModelProviders: [String]
}

struct SkillTableRowSnapshot: Sendable {
    let revision: Int
    let rows: [SkillTableRow]
}

/// Keeps expensive, revision-derived Skills rows alive while the Skills tab is
/// not selected. The SwiftUI Table itself still leaves the hierarchy so its
/// much larger AttributeGraph allocation can be reclaimed.
@MainActor
final class SkillTableRowStore: ObservableObject {
    typealias Builder = @Sendable (SkillTableBuildInputs) async -> [SkillTableRow]?

    @Published private(set) var snapshot: SkillTableRowSnapshot?

    private let builder: Builder
    private var generation = 0
    private var requestedRevision: Int?
    private var buildTask: Task<[SkillTableRow]?, Never>?

    init(builder: @escaping Builder = SkillTableRowStore.buildRows) {
        self.builder = builder
    }

    var rows: [SkillTableRow] {
        snapshot?.rows ?? []
    }

    func isReady(for revision: Int) -> Bool {
        snapshot?.revision == revision
    }

    /// Coalesces callers for one revision and rejects late results from every
    /// superseded generation. A caller's cancellation does not discard useful
    /// shared work; a newer revision explicitly cancels and replaces it.
    @discardableResult
    func load(revision: Int, inputs: SkillTableBuildInputs) async -> Bool {
        if isReady(for: revision) {
            return true
        }

        let requestGeneration: Int
        let task: Task<[SkillTableRow]?, Never>
        if requestedRevision == revision, let buildTask {
            requestGeneration = generation
            task = buildTask
        } else {
            buildTask?.cancel()
            generation += 1
            requestGeneration = generation
            requestedRevision = revision
            let builder = self.builder
            let newTask = Task<[SkillTableRow]?, Never>.detached(priority: .utility) {
                guard !Task.isCancelled else { return nil }
                return await builder(inputs)
            }
            buildTask = newTask
            task = newTask
        }

        let rows = await task.value
        if isReady(for: revision) {
            return true
        }
        guard generation == requestGeneration,
              requestedRevision == revision,
              let rows
        else {
            return false
        }

        AppBrand.clearSkillIconCache()
        snapshot = SkillTableRowSnapshot(revision: revision, rows: rows)
        buildTask = nil
        return true
    }

    nonisolated private static func buildRows(
        inputs: SkillTableBuildInputs
    ) async -> [SkillTableRow]? {
        guard !Task.isCancelled else { return nil }
        var canonicalizer = SkillPathCanonicalizer()
        let inventoryRows = InventorySkillRow.rows(
            from: inputs.projects,
            usage: inputs.usage,
            evaluations: inputs.evaluations,
            modelReleases: inputs.modelReleases,
            releaseAffirmations: inputs.releaseAffirmations,
            trackedModelProviders: inputs.trackedModelProviders,
            canonicalizer: &canonicalizer
        )

        guard !Task.isCancelled else { return nil }
        let overlaps = MetagentCore.detectSkillOverlaps(inventoryRows.map { $0.skill.coreSkill })

        guard !Task.isCancelled else { return nil }
        let usageRows = UsageSkillRow.rows(
            projects: inputs.projects,
            summaries: inputs.usage.summaries,
            isBackfillComplete: inputs.usage.isBackfillComplete,
            canonicalizer: &canonicalizer
        )

        guard !Task.isCancelled else { return nil }
        return SkillTableRow.rows(
            inventoryRows: inventoryRows,
            usageRows: usageRows,
            projectRoots: inputs.projects.map(\.root),
            pluginInventoryAvailable: inputs.pluginInventoryAvailable,
            isBackfillComplete: inputs.usage.isBackfillComplete,
            overlaps: overlaps,
            canonicalizer: &canonicalizer
        )
    }
}
