import XCTest
@testable import MetagentCore

final class SkillEvaluationBatchPolicyTests: XCTestCase {
    func testSingleEvaluationPublishesImmediately() {
        XCTAssertTrue(SkillEvaluationBatchPolicy.shouldPublish(completed: 1, total: 1))
    }

    func testLargeEvaluationPublishesAtBatchBoundariesAndCompletion() {
        XCTAssertFalse(SkillEvaluationBatchPolicy.shouldPublish(completed: 1, total: 45))
        XCTAssertFalse(SkillEvaluationBatchPolicy.shouldPublish(completed: 19, total: 45))
        XCTAssertTrue(SkillEvaluationBatchPolicy.shouldPublish(completed: 20, total: 45))
        XCTAssertTrue(SkillEvaluationBatchPolicy.shouldPublish(completed: 40, total: 45))
        XCTAssertTrue(SkillEvaluationBatchPolicy.shouldPublish(completed: 45, total: 45))
    }

    func testInvalidProgressDoesNotPublish() {
        XCTAssertFalse(SkillEvaluationBatchPolicy.shouldPublish(completed: 0, total: 10))
        XCTAssertFalse(SkillEvaluationBatchPolicy.shouldPublish(completed: 11, total: 10))
    }
}
