import XCTest
@testable import MetagentCore

final class ProductAnalyticsContractTests: XCTestCase {
    func testEventNamesUseStableObjectVerbFormat() {
        XCTAssertEqual(ProductAnalyticsEvent.appLaunched.name, "app launched")
        XCTAssertEqual(
            ProductAnalyticsEvent.skillPublicationEnabled(result: .success).name,
            "skill publication enabled"
        )
    }

    func testInventoryEventContainsOnlyAggregateRangesAndResult() {
        let event = ProductAnalyticsEvent.inventoryScanCompleted(
            result: .partial,
            projectCount: 3,
            skillCount: 87,
            warningCount: 1,
            failureCount: 0
        )

        XCTAssertEqual(event.properties, [
            "result": "partial",
            "project_count_range": "2-5",
            "skill_count_range": "51-100",
            "warning_count_range": "1",
            "failure_count_range": "0",
        ])
    }

    func testPublicationSyncUsesRangesInsteadOfExactCounts() {
        let event = ProductAnalyticsEvent.skillPublicationSyncCompleted(
            result: .success,
            publishedSkillCount: 7,
            blockedSkillCount: 0
        )

        XCTAssertEqual(event.properties, [
            "result": "success",
            "published_skill_count_range": "6-20",
            "blocked_skill_count_range": "0",
        ])
    }

    func testCountRangesClampNegativeInput() {
        XCTAssertEqual(ProductAnalyticsEvent.countRange(-4), "0")
        XCTAssertEqual(ProductAnalyticsEvent.countRange(1), "1")
        XCTAssertEqual(ProductAnalyticsEvent.countRange(5), "2-5")
        XCTAssertEqual(ProductAnalyticsEvent.countRange(20), "6-20")
        XCTAssertEqual(ProductAnalyticsEvent.countRange(50), "21-50")
        XCTAssertEqual(ProductAnalyticsEvent.countRange(100), "51-100")
        XCTAssertEqual(ProductAnalyticsEvent.countRange(101), "101+")
    }
}
