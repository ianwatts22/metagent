import Foundation
import MetagentCore
import Testing
@testable import MetagentMenuBar

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
