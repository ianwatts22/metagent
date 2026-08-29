import XCTest
@testable import MetagentCore

final class SkillUsageMaintenanceTests: XCTestCase {
    func testFirstContinuationPreservesCurrentForegroundAdjacentBudget() {
        let plan = SkillUsageMaintenancePlan.recommended(
            phase: .firstContinuation,
            isEnergyConstrained: false
        )

        XCTAssertEqual(plan.maxBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(plan.maxFiles, 12)
        XCTAssertEqual(plan.scheduleDelaySeconds, 45)
        XCTAssertEqual(plan.minimumDatabaseLeaseSeconds, 45)
        XCTAssertEqual(plan.throttleEveryBytes, 512 * 1_024)
        XCTAssertEqual(plan.throttleDelayMilliseconds, 25)
    }

    func testWatcherArmedCatchUpBatchesThreeNormalSlicesIntoOneWakeup() {
        let first = SkillUsageMaintenancePlan.recommended(
            phase: .firstContinuation,
            isEnergyConstrained: false
        )
        let catchUp = SkillUsageMaintenancePlan.recommended(
            phase: .watcherArmedCatchUp,
            isEnergyConstrained: false
        )

        XCTAssertEqual(catchUp.maxBytes, 24 * 1_024 * 1_024)
        XCTAssertEqual(catchUp.maxFiles, 36)
        XCTAssertEqual(catchUp.scheduleDelaySeconds, 135)
        XCTAssertEqual(catchUp.minimumDatabaseLeaseSeconds, 45)
        XCTAssertEqual(catchUp.maxBytes, first.maxBytes * 3)
        XCTAssertEqual(catchUp.maxFiles, first.maxFiles * 3)
        XCTAssertEqual(catchUp.scheduleDelaySeconds, first.scheduleDelaySeconds * 3)
    }

    func testWatcherArmedCatchUpPreservesByteAndFileRates() {
        let first = SkillUsageMaintenancePlan.recommended(
            phase: .firstContinuation,
            isEnergyConstrained: false
        )
        let catchUp = SkillUsageMaintenancePlan.recommended(
            phase: .watcherArmedCatchUp,
            isEnergyConstrained: false
        )

        XCTAssertEqual(
            first.maxBytes * Int64(catchUp.scheduleDelaySeconds),
            catchUp.maxBytes * Int64(first.scheduleDelaySeconds),
            "larger catch-up slices must reduce wakeups without increasing sustained byte rate"
        )
        XCTAssertEqual(
            first.maxFiles * Int(catchUp.scheduleDelaySeconds),
            catchUp.maxFiles * Int(first.scheduleDelaySeconds),
            "larger catch-up slices must reduce wakeups without increasing sustained file rate"
        )
    }

    func testConstrainedPlanPreservesExistingTwoMiBBudgetAndCadence() {
        let first = SkillUsageMaintenancePlan.recommended(
            phase: .firstContinuation,
            isEnergyConstrained: true
        )
        let catchUp = SkillUsageMaintenancePlan.recommended(
            phase: .watcherArmedCatchUp,
            isEnergyConstrained: true
        )

        for plan in [first, catchUp] {
            XCTAssertEqual(plan.maxBytes, 2 * 1_024 * 1_024)
            XCTAssertEqual(plan.maxFiles, 4)
            XCTAssertEqual(plan.scheduleDelaySeconds, 180)
            XCTAssertEqual(plan.minimumDatabaseLeaseSeconds, 180)
            XCTAssertEqual(plan.throttleEveryBytes, 256 * 1_024)
            XCTAssertEqual(plan.throttleDelayMilliseconds, 50)
        }
    }

    func testRefreshOptionsUseDatabaseLeaseRatherThanScheduleDelay() {
        let plan = SkillUsageMaintenancePlan.recommended(
            phase: .watcherArmedCatchUp,
            isEnergyConstrained: false
        )
        let options = plan.refreshOptions(databasePath: "/tmp/test-usage.sqlite")

        XCTAssertEqual(options.databasePath, "/tmp/test-usage.sqlite")
        XCTAssertEqual(options.maxBytes, plan.maxBytes)
        XCTAssertEqual(options.maxFiles, plan.maxFiles)
        XCTAssertEqual(options.throttleEveryBytes, plan.throttleEveryBytes)
        XCTAssertEqual(options.throttleDelayMilliseconds, plan.throttleDelayMilliseconds)
        XCTAssertEqual(options.minimumMaintenanceIntervalSeconds, 45)
        XCTAssertNotEqual(options.minimumMaintenanceIntervalSeconds, plan.scheduleDelaySeconds)
        XCTAssertTrue(options.reusesSourceCatalog)
        XCTAssertEqual(options.sourceCatalogMaximumAgeSeconds, 15 * 60)
    }

    func testTailClampBoundsBothBudgetsWithoutChangingCadence() throws {
        let plan = SkillUsageMaintenancePlan.recommended(
            phase: .watcherArmedCatchUp,
            isEnergyConstrained: false
        )
        let clamped = try XCTUnwrap(plan.clampedToTail(
            remainingBytes: 3 * 1_024 * 1_024,
            remainingFiles: 5
        ))

        XCTAssertEqual(clamped.maxBytes, 3 * 1_024 * 1_024)
        XCTAssertEqual(clamped.maxFiles, 5)
        XCTAssertEqual(clamped.scheduleDelaySeconds, plan.scheduleDelaySeconds)
        XCTAssertEqual(clamped.minimumDatabaseLeaseSeconds, plan.minimumDatabaseLeaseSeconds)
        XCTAssertEqual(clamped.throttleEveryBytes, plan.throttleEveryBytes)
        XCTAssertEqual(clamped.throttleDelayMilliseconds, plan.throttleDelayMilliseconds)
    }

    func testTailClampNeverExpandsAnAlreadyBoundedPlan() throws {
        let plan = SkillUsageMaintenancePlan.recommended(
            phase: .firstContinuation,
            isEnergyConstrained: false
        )
        let clamped = try XCTUnwrap(plan.clampedToTail(
            remainingBytes: Int64.max,
            remainingFiles: Int.max
        ))

        XCTAssertEqual(clamped, plan)
    }

    func testExhaustedOrInvalidTailProducesNoMaintenancePlan() {
        let plan = SkillUsageMaintenancePlan.recommended(isEnergyConstrained: false)

        XCTAssertNil(plan.clampedToTail(remainingBytes: 0, remainingFiles: 1))
        XCTAssertNil(plan.clampedToTail(remainingBytes: 1, remainingFiles: 0))
        XCTAssertNil(plan.clampedToTail(remainingBytes: -1, remainingFiles: 1))
        XCTAssertNil(plan.clampedToTail(remainingBytes: 1, remainingFiles: -1))
    }

    func testExplicitPlanClampsUnsafeBudgetsAndIntervals() {
        let plan = SkillUsageMaintenancePlan(
            maxBytes: 0,
            maxFiles: 0,
            scheduleDelaySeconds: 0,
            minimumDatabaseLeaseSeconds: 0,
            throttleEveryBytes: -1,
            throttleDelayMilliseconds: -1
        )

        XCTAssertEqual(plan.maxBytes, 1)
        XCTAssertEqual(plan.maxFiles, 1)
        XCTAssertEqual(plan.scheduleDelaySeconds, 1)
        XCTAssertEqual(plan.minimumDatabaseLeaseSeconds, 1)
        XCTAssertEqual(plan.throttleEveryBytes, 0)
        XCTAssertEqual(plan.throttleDelayMilliseconds, 0)
    }

    func testForegroundRefreshDefaultsRemainUnthrottled() {
        let options = SkillUsageRefreshOptions(maxBytes: 8 * 1_024 * 1_024, maxFiles: 12)

        XCTAssertEqual(options.throttleEveryBytes, 0)
        XCTAssertEqual(options.throttleDelayMilliseconds, 0)
        XCTAssertEqual(options.minimumMaintenanceIntervalSeconds, 0)
        XCTAssertFalse(options.reusesSourceCatalog)
    }

    func testExplicitPlanKeepsLegacyUnthrottledDefaults() {
        let plan = SkillUsageMaintenancePlan(
            maxBytes: 1_024,
            maxFiles: 1,
            delaySeconds: 10
        )

        XCTAssertEqual(plan.throttleEveryBytes, 0)
        XCTAssertEqual(plan.throttleDelayMilliseconds, 0)
        XCTAssertEqual(plan.scheduleDelaySeconds, 10)
        XCTAssertEqual(plan.minimumDatabaseLeaseSeconds, 10)
    }

    func testScheduleUsesAbsoluteDeadlinesAcrossPhaseTransition() throws {
        var schedule = SkillUsageMaintenanceSchedule()
        let first = try XCTUnwrap(schedule.plan(
            isEnergyConstrained: false,
            remainingBytes: 80 * 1_024 * 1_024,
            remainingFiles: 80
        ))
        XCTAssertEqual(schedule.delayBeforeNextRun(plan: first, nowUptime: 1_000), 45)
        XCTAssertEqual(schedule.nextDueUptime, 1_045)

        schedule.recordCompletion(wasDeferred: false)
        let catchUp = try XCTUnwrap(schedule.plan(
            isEnergyConstrained: false,
            remainingBytes: 72 * 1_024 * 1_024,
            remainingFiles: 68
        ))
        XCTAssertEqual(catchUp.maxBytes, 24 * 1_024 * 1_024)
        XCTAssertEqual(
            schedule.delayBeforeNextRun(plan: catchUp, nowUptime: 1_050),
            130,
            "five seconds of slice work must come out of the next wait rather than reducing throughput"
        )
        XCTAssertEqual(schedule.nextDueUptime, 1_180)
    }

    func testDeferredFirstContinuationDoesNotArmCatchUpPhase() throws {
        var schedule = SkillUsageMaintenanceSchedule()
        schedule.recordCompletion(wasDeferred: true)

        let plan = try XCTUnwrap(schedule.plan(
            isEnergyConstrained: false,
            remainingBytes: 16 * 1_024 * 1_024,
            remainingFiles: 24
        ))
        XCTAssertEqual(schedule.phase, .firstContinuation)
        XCTAssertEqual(plan.maxBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(plan.scheduleDelaySeconds, 45)
    }

    func testScheduleClampsTailAndStopsWhenComplete() throws {
        var schedule = SkillUsageMaintenanceSchedule()
        schedule.recordCompletion(wasDeferred: false)

        let tail = try XCTUnwrap(schedule.plan(
            isEnergyConstrained: false,
            remainingBytes: 3 * 1_024 * 1_024,
            remainingFiles: 2
        ))
        XCTAssertEqual(tail.maxBytes, 3 * 1_024 * 1_024)
        XCTAssertEqual(tail.maxFiles, 2)
        XCTAssertNil(schedule.plan(
            isEnergyConstrained: false,
            remainingBytes: 0,
            remainingFiles: 0
        ))
    }

    func testResetDeadlineStartsANewCadenceFromNow() {
        var schedule = SkillUsageMaintenanceSchedule()
        let plan = SkillUsageMaintenancePlan.recommended(isEnergyConstrained: false)
        XCTAssertEqual(schedule.delayBeforeNextRun(plan: plan, nowUptime: 10), 45)
        schedule.resetDeadline()
        XCTAssertEqual(schedule.delayBeforeNextRun(plan: plan, nowUptime: 1_000), 45)
        XCTAssertEqual(schedule.nextDueUptime, 1_045)
    }

    func testScheduleToleranceScalesWithoutExceedingThirtySeconds() {
        let first = SkillUsageMaintenancePlan.recommended(
            phase: .firstContinuation,
            isEnergyConstrained: false
        )
        let catchUp = SkillUsageMaintenancePlan.recommended(
            phase: .watcherArmedCatchUp,
            isEnergyConstrained: false
        )
        let constrained = SkillUsageMaintenancePlan.recommended(
            phase: .watcherArmedCatchUp,
            isEnergyConstrained: true
        )

        XCTAssertEqual(first.scheduleToleranceSeconds, 5)
        XCTAssertEqual(catchUp.scheduleToleranceSeconds, 15)
        XCTAssertEqual(constrained.scheduleToleranceSeconds, 20)
        XCTAssertLessThanOrEqual(constrained.scheduleToleranceSeconds, 30)
    }
}
