import Foundation
import MetagentCore
import Testing
@testable import MetagentMenuBar

@MainActor
@Test func cancelledSkillCollectionLoadCannotPublishOrClearNewBusyState() async {
    let loader = ProjectSkillSyncCollectionLoader()
    let oldScan = SuspendedSkillCollectionScan()
    let newScan = SuspendedSkillCollectionScan()
    let oldTask = Task { await loader.load(.agents, scan: { _ in try await oldScan.scan().map(available) }) }
    await oldScan.waitUntilStarted()
    oldTask.cancel()
    let newTask = Task { await loader.load(.codex, scan: { _ in try await newScan.scan().map(available) }) }
    await newScan.waitUntilStarted()
    await oldScan.finish(.success(["old-agents-skill"]))
    await oldTask.value
    #expect(loader.names.isEmpty)
    #expect(loader.isLoading)
    #expect(loader.error == nil)
    await newScan.finish(.success(["current-codex-skill"]))
    await newTask.value
    #expect(loader.names == ["current-codex-skill"])
    #expect(!loader.isLoading)
}

@MainActor
@Test(arguments: [false, true])
func staleSameCollectionLoadCannotOverwriteLatestResult(fails: Bool) async {
    let loader = ProjectSkillSyncCollectionLoader()
    let oldScan = SuspendedSkillCollectionScan()
    let newScan = SuspendedSkillCollectionScan()
    let oldTask = Task { await loader.load(.agents, scan: { _ in try await oldScan.scan().map(available) }) }
    await oldScan.waitUntilStarted()
    let newTask = Task { await loader.load(.agents, scan: { _ in try await newScan.scan().map(available) }) }
    await newScan.waitUntilStarted()
    await newScan.finish(.success(["newest-skill"]))
    await newTask.value
    if fails {
        await oldScan.finish(.failure(NSError(domain: "SyntheticCollectionScan", code: 1)))
    } else {
        await oldScan.finish(.success(["stale-skill"]))
    }
    await oldTask.value
    #expect(loader.names == ["newest-skill"])
    #expect(!loader.isLoading)
    #expect(loader.error == nil)
}

private func available(_ name: String) -> ProjectSkillSyncCandidate {
    ProjectSkillSyncCandidate(name: name, status: .available)
}

private actor SuspendedSkillCollectionScan {
    private var continuation: CheckedContinuation<[String], Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    func scan() async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish(_ result: Result<[String], Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
