import MetagentCore
import Testing
@testable import MetagentMenuBar

@Test func catalogDistinguishesPendingEmptyAndFailedScans() {
    var state = InventoryCatalogState.cataloging
    state.completeScan(succeeded: false)
    #expect(state == .failed)
    state.beginScan()
    #expect(state == .cataloging)
    state.completeScan(succeeded: true)
    #expect(state == .ready)
    state.beginScan()
    #expect(state == .ready) // Warm refresh must not replace usable content.
}

@MainActor
@Test func firstLaunchShowsCatalogingBeforeAndAfterCacheHydration() async {
    let model = MetagentModel(launchCacheLoader: .init(
        loadInventory: { nil },
        loadDeferred: { .init(usage: nil, evaluations: .init(), modelReleases: .empty,
                              releaseAffirmations: [:], publications: .empty) }
    ))
    #expect(model.catalogState == .cataloging)
    #expect(model.activity?.needsAttention == false)
    await model.hydrateLaunchCaches()
    #expect(model.catalogState == .cataloging)
}

@MainActor
@Test func cachedEmptyInventoryIsAResultNotAnUnfinishedScan() {
    let model = MetagentModel(launchCacheLoader: .init(
        loadInventory: { SkillScanReport(projects: [], warnings: []) },
        loadDeferred: { .init(usage: nil, evaluations: .init(), modelReleases: .empty,
                              releaseAffirmations: [:], publications: .empty) }
    ))
    #expect(model.catalogState == .ready)
}
