import Foundation
import XCTest
@testable import MetagentCore

final class MetagentCorePerformanceTestsSingleSkillDetail: XCTestCase {
    func testPerformanceSingleSkillDetailInDenseProject() throws {
        guard ProcessInfo.processInfo.environment["METAGENT_RUN_PERFORMANCE_TESTS"] == "1" else { return }
        let root = try makeTemporaryRoot(prefix: "metagent-performance-single-detail")
        for index in 0..<192 {
            let bundle = root.appendingPathComponent(".agents/skills/skill-\(index)")
            try writeSkillFixture(at: bundle, name: "skill-\(index)", body: "Run scripts/demo.py. Unicode café 東京.")
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("references"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try String(repeating: "Reference scripts/demo.py. Unicode 👩🏽‍💻.\n", count: 128).write(
                to: bundle.appendingPathComponent("references/guide.md"), atomically: true, encoding: .utf8
            )
            try "#!/usr/bin/env python3\nprint('synthetic')\n".write(
                to: bundle.appendingPathComponent("scripts/demo.py"), atomically: true, encoding: .utf8
            )
        }
        let path = root.appendingPathComponent(".agents/skills/skill-0").path
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let expected = try MetagentCore.getSkillDetail(
            path: path, now: now,
            readInventory: { inferred, _ in
                try MetagentCore.scanSkills(
                    options: SkillScanOptions(roots: [inferred.path], maxDepth: 0, respectConfiguredIgnores: false),
                    config: MetagentConfig(roots: [root.path])
                )
            },
            loadUsage: { .empty }
        )
        let operation = {
            try MetagentCore.getSkillDetail(
                path: path, now: now,
                readInventory: { inferred, directory in
                    try MetagentCore.skillDetailInventory(root: inferred, directory: directory, config: MetagentConfig(roots: [root.path]))
                },
                loadUsage: { .empty }
            )
        }
        let started = ProcessInfo.processInfo.systemUptime
        let preflight = try operation()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let configuredMultiplier = Double(
            ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_BUDGET_MULTIPLIER"] ?? ""
        ) ?? 1
        let budget = min(max(configuredMultiplier, 0.5), 10)
        print("[Metagent performance] single-skill detail: \(String(format: "%.3f", elapsed))s (budget \(String(format: "%.3f", budget))s)")
        // Broad component regression rail; not installed-app interaction latency.
        XCTAssertLessThanOrEqual(elapsed, budget)
        XCTAssertEqual(preflight, expected)
        let options = XCTMeasureOptions()
        let configured = Int(ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_ITERATIONS"] ?? "") ?? 5
        options.iterationCount = min(max(configured, 1), 20)
        var measured: SkillDetail?
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(), XCTStorageMetric()], options: options) {
            measured = try! operation()
        }
        XCTAssertEqual(measured, expected)
    }
}
