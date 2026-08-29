import Foundation
import MetagentCore
import Testing
@testable import MetagentMenuBar

private final class LaunchLoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [String] = []

    func record(_ call: String) {
        lock.withLock {
            recordedCalls.append(call)
        }
    }

    var calls: [String] {
        lock.withLock { recordedCalls }
    }
}

@MainActor
@Test func launchDefersNonvisualCachesUntilHydration() async {
    let recorder = LaunchLoadRecorder()
    let loader = MetagentLaunchCacheLoader(
        loadInventory: {
            recorder.record("inventory")
            return nil
        },
        loadDeferred: {
            recorder.record("deferred")
            return MetagentDeferredLaunchSnapshot(
                usage: nil,
                evaluations: SkillEvaluationSnapshot(),
                modelReleases: .empty,
                releaseAffirmations: [:],
                publications: .empty
            )
        }
    )

    let model = MetagentModel(launchCacheLoader: loader)
    #expect(recorder.calls == ["inventory"])
    let initialRevision = model.skillTableRevision

    await model.hydrateLaunchCaches()
    #expect(recorder.calls == ["inventory", "deferred"])
    #expect(model.usageSnapshot == .empty)
    #expect(model.modelReleases == .empty)
    #expect(model.publicationSnapshot == .empty)
    #expect(model.hasHydratedLaunchCaches)
    #expect(model.skillTableRevision == initialRevision)
}

@MainActor
@Test func automaticEvaluationWaitsForLaunchCacheHydration() async {
    let loader = MetagentLaunchCacheLoader(
        loadInventory: { nil },
        loadDeferred: {
            MetagentDeferredLaunchSnapshot(
                usage: nil,
                evaluations: SkillEvaluationSnapshot(),
                modelReleases: .empty,
                releaseAffirmations: [:],
                publications: .empty
            )
        }
    )
    let model = MetagentModel(launchCacheLoader: loader)

    model.evaluateMissingSkills(paths: ["/private/tmp/should-not-run-before-hydration"])
    #expect(!model.isSkillEvaluating)

    await model.hydrateLaunchCaches()
    #expect(model.hasHydratedLaunchCaches)
}

@Test func overviewHealthRefreshWaitsForHydrationAndRetriggersForEveryInput() {
    let waiting = OverviewSkillHealthRefreshTrigger(
        hasHydratedLaunchCaches: false,
        skillTableRevision: 7,
        selectedProjectRoot: nil,
        trendRange: "30d"
    )
    let hydrated = OverviewSkillHealthRefreshTrigger(
        hasHydratedLaunchCaches: true,
        skillTableRevision: 7,
        selectedProjectRoot: nil,
        trendRange: "30d"
    )

    #expect(!waiting.shouldRefresh)
    #expect(hydrated.shouldRefresh)
    #expect(waiting != hydrated)
    #expect(hydrated != OverviewSkillHealthRefreshTrigger(
        hasHydratedLaunchCaches: true,
        skillTableRevision: 8,
        selectedProjectRoot: nil,
        trendRange: "30d"
    ))
    #expect(hydrated != OverviewSkillHealthRefreshTrigger(
        hasHydratedLaunchCaches: true,
        skillTableRevision: 7,
        selectedProjectRoot: "/private/tmp/project",
        trendRange: "30d"
    ))
    #expect(hydrated != OverviewSkillHealthRefreshTrigger(
        hasHydratedLaunchCaches: true,
        skillTableRevision: 7,
        selectedProjectRoot: nil,
        trendRange: "90d"
    ))
}
