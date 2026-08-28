import XCTest
@testable import MetagentCore

final class SkillUsageMaintenanceTests: XCTestCase {
    func testNormalPlanMakesProgressWithoutAnUnboundedRun() {
        let plan = SkillUsageMaintenancePlan.recommended(isEnergyConstrained: false)

        XCTAssertEqual(plan.maxBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(plan.maxFiles, 12)
        XCTAssertEqual(plan.delaySeconds, 45)
    }

    func testConstrainedPlanReducesWorkAndWakeFrequency() {
        let normal = SkillUsageMaintenancePlan.recommended(isEnergyConstrained: false)
        let constrained = SkillUsageMaintenancePlan.recommended(isEnergyConstrained: true)

        XCTAssertLessThan(constrained.maxBytes, normal.maxBytes)
        XCTAssertLessThan(constrained.maxFiles, normal.maxFiles)
        XCTAssertGreaterThan(constrained.delaySeconds, normal.delaySeconds)
    }
}
