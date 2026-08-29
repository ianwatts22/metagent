import Foundation

/// A bounded background slice that advances an incomplete usage index without
/// turning parser maintenance into a sustained foreground workload.
public struct SkillUsageMaintenancePlan: Sendable, Equatable {
    public let maxBytes: Int64
    public let maxFiles: Int
    public let delaySeconds: TimeInterval
    public let throttleEveryBytes: Int64
    public let throttleDelayMilliseconds: Int

    public init(
        maxBytes: Int64,
        maxFiles: Int,
        delaySeconds: TimeInterval,
        throttleEveryBytes: Int64 = 0,
        throttleDelayMilliseconds: Int = 0
    ) {
        self.maxBytes = max(1, maxBytes)
        self.maxFiles = max(1, maxFiles)
        self.delaySeconds = max(1, delaySeconds)
        self.throttleEveryBytes = max(0, throttleEveryBytes)
        self.throttleDelayMilliseconds = max(0, throttleDelayMilliseconds)
    }

    /// Converts one energy policy into parser options as a single unit so the
    /// app cannot accidentally apply the slice limits without the intra-slice
    /// pacing. Explicit foreground refreshes construct their own unthrottled
    /// options and remain as responsive as before.
    public func refreshOptions(databasePath: String? = nil) -> SkillUsageRefreshOptions {
        SkillUsageRefreshOptions(
            databasePath: databasePath,
            maxBytes: maxBytes,
            maxFiles: maxFiles,
            throttleEveryBytes: throttleEveryBytes,
            throttleDelayMilliseconds: throttleDelayMilliseconds,
            minimumMaintenanceIntervalSeconds: delaySeconds,
            reusesSourceCatalog: true
        )
    }

    public static func recommended(isEnergyConstrained: Bool) -> Self {
        if isEnergyConstrained {
            return Self(
                maxBytes: 2 * 1_024 * 1_024,
                maxFiles: 4,
                delaySeconds: 180,
                throttleEveryBytes: 256 * 1_024,
                throttleDelayMilliseconds: 50
            )
        }
        return Self(
            maxBytes: 8 * 1_024 * 1_024,
            maxFiles: 12,
            delaySeconds: 45,
            throttleEveryBytes: 512 * 1_024,
            throttleDelayMilliseconds: 25
        )
    }
}
