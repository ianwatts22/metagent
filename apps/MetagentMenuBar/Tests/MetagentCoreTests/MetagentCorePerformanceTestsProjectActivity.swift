import Foundation
import XCTest
@testable import MetagentCore

// XCTMeasureOptions and the clock/memory metrics are macOS XCTest only.
#if os(macOS)
/// Metadata-only component measurements, not installed-app refresh latency.
/// The class name keeps these scenarios in the existing opt-in Core filter.
final class MetagentCorePerformanceTestsProjectActivity: XCTestCase {
    func testPerformanceOrdinaryProjectActivity() throws {
        try measureProjectActivity(directoryCount: 12, requestedCount: 12)
    }

    func testPerformanceSparseProjectActivity() throws {
        try measureProjectActivity(directoryCount: 120, requestedCount: 12)
    }

    func testPerformanceAllRequestedProjectActivity() throws {
        try measureProjectActivity(directoryCount: 120, requestedCount: 120)
    }

    private func measureProjectActivity(directoryCount: Int, requestedCount: Int) throws {
        guard ProcessInfo.processInfo.environment["METAGENT_RUN_PERFORMANCE_TESTS"] == "1" else { return }
        let corpus = FileManager.default.temporaryDirectory
            .appendingPathComponent("metagent-performance-project-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: corpus) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let roots = (0..<directoryCount).map { "/synthetic/projects/project_\($0)" }
        var expectedDates: [String: Date] = [:]
        for (index, root) in roots.enumerated() {
            let directory = corpus.appendingPathComponent(sessionDirectoryName(for: root))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for session in 0..<48 {
                let path = directory.appendingPathComponent("session_\(session).jsonl")
                try Data().write(to: path)
                let modifiedAt = date.addingTimeInterval(Double(index * 100 + session))
                try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: path.path)
                if index < requestedCount { expectedDates[root] = modifiedAt }
            }
            for ignoredName in [".hidden.jsonl", "ignored.txt"] {
                let path = directory.appendingPathComponent(ignoredName)
                try Data().write(to: path)
                try FileManager.default.setAttributes(
                    [.modificationDate: date.addingTimeInterval(100_000)],
                    ofItemAtPath: path.path
                )
            }
        }
        let requestedRoots = Array(roots.prefix(requestedCount))
        let expected = ProjectActivityIndex(lastActiveByRoot: expectedDates, isAvailable: true)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let preflight = MetagentCore.scanProjectActivity(roots: requestedRoots, sessionsDirectory: corpus)
        let configuredMultiplier = Double(
            ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_BUDGET_MULTIPLIER"] ?? ""
        ) ?? 1
        XCTAssertLessThanOrEqual(
            ProcessInfo.processInfo.systemUptime - startedAt,
            2 * min(max(configuredMultiplier, 0.5), 10),
            "Project activity metadata scan exceeded its broad component regression budget"
        )
        XCTAssertEqual(preflight, expected)

        let configuredIterations = Int(
            ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_ITERATIONS"] ?? ""
        ) ?? 5
        let options = XCTMeasureOptions()
        options.iterationCount = min(max(configuredIterations, 1), 20)
        var measuredIndex: ProjectActivityIndex?
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(), XCTStorageMetric()], options: options) {
            measuredIndex = MetagentCore.scanProjectActivity(roots: requestedRoots, sessionsDirectory: corpus)
        }
        XCTAssertEqual(measuredIndex, expected)
    }
}
#endif
