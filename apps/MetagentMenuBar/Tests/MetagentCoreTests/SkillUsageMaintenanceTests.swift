import XCTest
@testable import MetagentCore

final class SkillUsageMaintenanceTests: XCTestCase {
    func testNormalPlanMakesProgressWithoutAnUnboundedRun() {
        let plan = SkillUsageMaintenancePlan.recommended(isEnergyConstrained: false)

        XCTAssertEqual(plan.maxBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(plan.maxFiles, 12)
        XCTAssertEqual(plan.delaySeconds, 45)
        XCTAssertEqual(plan.throttleEveryBytes, 512 * 1_024)
        XCTAssertEqual(plan.throttleDelayMilliseconds, 25)
    }

    func testConstrainedPlanReducesWorkAndWakeFrequency() {
        let normal = SkillUsageMaintenancePlan.recommended(isEnergyConstrained: false)
        let constrained = SkillUsageMaintenancePlan.recommended(isEnergyConstrained: true)

        XCTAssertLessThan(constrained.maxBytes, normal.maxBytes)
        XCTAssertLessThan(constrained.maxFiles, normal.maxFiles)
        XCTAssertGreaterThan(constrained.delaySeconds, normal.delaySeconds)
        XCTAssertLessThan(constrained.throttleEveryBytes, normal.throttleEveryBytes)
        XCTAssertGreaterThan(constrained.throttleDelayMilliseconds, normal.throttleDelayMilliseconds)
    }

    func testRefreshOptionsKeepBackgroundPacingTogether() {
        let plan = SkillUsageMaintenancePlan.recommended(isEnergyConstrained: false)
        let options = plan.refreshOptions(databasePath: "/tmp/test-usage.sqlite")

        XCTAssertEqual(options.databasePath, "/tmp/test-usage.sqlite")
        XCTAssertEqual(options.maxBytes, plan.maxBytes)
        XCTAssertEqual(options.maxFiles, plan.maxFiles)
        XCTAssertEqual(options.throttleEveryBytes, plan.throttleEveryBytes)
        XCTAssertEqual(options.throttleDelayMilliseconds, plan.throttleDelayMilliseconds)
        XCTAssertEqual(options.minimumMaintenanceIntervalSeconds, plan.delaySeconds)
    }

    func testForegroundRefreshDefaultsRemainUnthrottled() {
        let options = SkillUsageRefreshOptions(maxBytes: 8 * 1_024 * 1_024, maxFiles: 12)

        XCTAssertEqual(options.throttleEveryBytes, 0)
        XCTAssertEqual(options.throttleDelayMilliseconds, 0)
        XCTAssertEqual(options.minimumMaintenanceIntervalSeconds, 0)
    }

    func testExplicitPlanKeepsLegacyUnthrottledDefaults() {
        let plan = SkillUsageMaintenancePlan(
            maxBytes: 1_024,
            maxFiles: 1,
            delaySeconds: 10
        )

        XCTAssertEqual(plan.throttleEveryBytes, 0)
        XCTAssertEqual(plan.throttleDelayMilliseconds, 0)
    }
}
