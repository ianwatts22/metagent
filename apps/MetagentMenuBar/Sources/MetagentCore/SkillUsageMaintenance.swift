import Foundation

/// A bounded background slice that advances an incomplete usage index without
/// turning parser maintenance into a sustained foreground workload.
public struct SkillUsageMaintenancePlan: Sendable, Equatable {
    public let maxBytes: Int64
    public let maxFiles: Int
    public let delaySeconds: TimeInterval

    public init(maxBytes: Int64, maxFiles: Int, delaySeconds: TimeInterval) {
        self.maxBytes = max(1, maxBytes)
        self.maxFiles = max(1, maxFiles)
        self.delaySeconds = max(1, delaySeconds)
    }

    public static func recommended(isEnergyConstrained: Bool) -> Self {
        if isEnergyConstrained {
            return Self(
                maxBytes: 2 * 1_024 * 1_024,
                maxFiles: 4,
                delaySeconds: 180
            )
        }
        return Self(
            maxBytes: 8 * 1_024 * 1_024,
            maxFiles: 12,
            delaySeconds: 45
        )
    }
}
