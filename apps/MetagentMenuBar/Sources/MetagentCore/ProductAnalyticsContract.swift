import Foundation

public enum ProductAnalyticsResult: String, Sendable {
    case success
    case partial
    case failure
}

/// The complete public analytics contract for the native app. Cases accept
/// only bounded outcomes and aggregate counts, so call sites cannot
/// accidentally attach skill names, content, or filesystem paths.
public enum ProductAnalyticsEvent: Sendable, Equatable {
    case appLaunched
    case inventoryScanCompleted(
        result: ProductAnalyticsResult,
        projectCount: Int,
        skillCount: Int,
        warningCount: Int,
        failureCount: Int
    )
    case skillPublicationEnabled(result: ProductAnalyticsResult)
    case skillPublicationSyncCompleted(
        result: ProductAnalyticsResult,
        publishedSkillCount: Int,
        blockedSkillCount: Int
    )

    public var name: String {
        switch self {
        case .appLaunched:
            "app launched"
        case .inventoryScanCompleted:
            "inventory scan completed"
        case .skillPublicationEnabled:
            "skill publication enabled"
        case .skillPublicationSyncCompleted:
            "skill publication sync completed"
        }
    }

    public var properties: [String: String] {
        switch self {
        case .appLaunched:
            [:]
        case let .inventoryScanCompleted(
            result,
            projectCount,
            skillCount,
            warningCount,
            failureCount
        ):
            [
                "result": result.rawValue,
                "project_count_range": Self.countRange(projectCount),
                "skill_count_range": Self.countRange(skillCount),
                "warning_count_range": Self.countRange(warningCount),
                "failure_count_range": Self.countRange(failureCount),
            ]
        case let .skillPublicationEnabled(result):
            ["result": result.rawValue]
        case let .skillPublicationSyncCompleted(
            result,
            publishedSkillCount,
            blockedSkillCount
        ):
            [
                "result": result.rawValue,
                "published_skill_count_range": Self.countRange(publishedSkillCount),
                "blocked_skill_count_range": Self.countRange(blockedSkillCount),
            ]
        }
    }

    public static func countRange(_ count: Int) -> String {
        switch max(0, count) {
        case 0: "0"
        case 1: "1"
        case 2...5: "2-5"
        case 6...20: "6-20"
        case 21...50: "21-50"
        case 51...100: "51-100"
        default: "101+"
        }
    }
}
