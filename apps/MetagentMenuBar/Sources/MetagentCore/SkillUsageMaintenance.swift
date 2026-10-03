import Foundation
import IOKit.ps

/// The normal-power phase of a cooperative usage backfill.
///
/// The first continuation stays small so launch work does not immediately turn
/// into a long background burst. Once the filesystem watcher is armed, the app
/// can select faster, time-bounded catch-up on external power. Battery and
/// constrained operation retain their conservative byte and file rates.
public enum SkillUsageMaintenancePhase: Sendable, Equatable {
    case firstContinuation
    case watcherArmedCatchUp
}

/// A bounded background slice that advances an incomplete usage index without
/// turning parser maintenance into a sustained foreground workload.
public struct SkillUsageMaintenancePlan: Sendable, Equatable {
    public let maxBytes: Int64
    public let maxFiles: Int
    /// Time the app should sleep before starting this slice.
    public let scheduleDelaySeconds: TimeInterval
    /// Minimum interval used when claiming the shared SQLite maintenance lane.
    /// This is deliberately independent from the app's scheduling cadence:
    /// batching three slices into one wakeup must not also lengthen the
    /// cross-process exclusion window by three times.
    public let minimumDatabaseLeaseSeconds: TimeInterval
    public let throttleEveryBytes: Int64
    public let throttleDelayMilliseconds: Int
    public let maximumDurationSeconds: TimeInterval

    /// Compatibility for the current scheduler while it migrates to the more
    /// precise `scheduleDelaySeconds` name.
    public var delaySeconds: TimeInterval { scheduleDelaySeconds }

    /// Lets macOS coalesce maintenance timers with other process wakeups. The
    /// first continuation remains relatively precise; longer catch-up and
    /// constrained intervals intentionally allow a wider energy-saving window.
    public var scheduleToleranceSeconds: TimeInterval {
        min(30, max(1, scheduleDelaySeconds / 9))
    }

    public init(
        maxBytes: Int64,
        maxFiles: Int,
        scheduleDelaySeconds: TimeInterval,
        minimumDatabaseLeaseSeconds: TimeInterval,
        throttleEveryBytes: Int64 = 0,
        throttleDelayMilliseconds: Int = 0,
        maximumDurationSeconds: TimeInterval = 0
    ) {
        self.maxBytes = max(1, maxBytes)
        self.maxFiles = max(1, maxFiles)
        self.scheduleDelaySeconds = max(1, scheduleDelaySeconds)
        self.minimumDatabaseLeaseSeconds = max(1, minimumDatabaseLeaseSeconds)
        self.throttleEveryBytes = max(0, throttleEveryBytes)
        self.throttleDelayMilliseconds = max(0, throttleDelayMilliseconds)
        self.maximumDurationSeconds = max(0, maximumDurationSeconds)
    }

    /// Compatibility initializer for callers that intentionally want one
    /// interval to govern both scheduling and the shared-database claim.
    public init(
        maxBytes: Int64,
        maxFiles: Int,
        delaySeconds: TimeInterval,
        throttleEveryBytes: Int64 = 0,
        throttleDelayMilliseconds: Int = 0
    ) {
        self.init(
            maxBytes: maxBytes,
            maxFiles: maxFiles,
            scheduleDelaySeconds: delaySeconds,
            minimumDatabaseLeaseSeconds: delaySeconds,
            throttleEveryBytes: throttleEveryBytes,
            throttleDelayMilliseconds: throttleDelayMilliseconds
        )
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
            maximumDurationSeconds: maximumDurationSeconds,
            minimumMaintenanceIntervalSeconds: minimumDatabaseLeaseSeconds,
            reusesSourceCatalog: true
        )
    }

    /// Returns the deterministic policy for one continuation phase. Foreground
    /// refreshes do not use this planner and remain unthrottled.
    public static func recommended(
        phase: SkillUsageMaintenancePhase,
        isEnergyConstrained: Bool,
        isOnExternalPower: Bool = false
    ) -> Self {
        if isEnergyConstrained {
            return Self(
                maxBytes: 2 * 1_024 * 1_024,
                maxFiles: 4,
                scheduleDelaySeconds: 180,
                minimumDatabaseLeaseSeconds: 180,
                throttleEveryBytes: 256 * 1_024,
                throttleDelayMilliseconds: 50
            )
        }

        switch phase {
        case .firstContinuation:
            return Self(
                maxBytes: 8 * 1_024 * 1_024,
                maxFiles: 12,
                scheduleDelaySeconds: 45,
                minimumDatabaseLeaseSeconds: 45,
                throttleEveryBytes: 512 * 1_024,
                throttleDelayMilliseconds: 25
            )
        case .watcherArmedCatchUp:
            if isOnExternalPower {
                return Self(
                    maxBytes: 32 * 1_024 * 1_024,
                    maxFiles: 48,
                    scheduleDelaySeconds: 12,
                    minimumDatabaseLeaseSeconds: 12,
                    throttleEveryBytes: 512 * 1_024,
                    throttleDelayMilliseconds: 25,
                    maximumDurationSeconds: 2
                )
            }
            return Self(
                maxBytes: 24 * 1_024 * 1_024,
                maxFiles: 36,
                scheduleDelaySeconds: 135,
                minimumDatabaseLeaseSeconds: 45,
                throttleEveryBytes: 512 * 1_024,
                throttleDelayMilliseconds: 25
            )
        }
    }

    /// Keeps the existing scheduler on the conservative first-continuation
    /// policy until it explicitly records that the watcher is armed.
    public static func recommended(isEnergyConstrained: Bool) -> Self {
        recommended(phase: .firstContinuation, isEnergyConstrained: isEnergyConstrained)
    }

    /// Unknown power sources fail conservatively, including UPS/battery power.
    public static func hasExternalPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return source as String == kIOPSACPowerValue
    }

    /// Clamps a policy to the known unprocessed tail. Returning `nil` for an
    /// exhausted tail prevents a nominal one-byte/one-file plan from creating
    /// an otherwise unnecessary wakeup.
    public func clampedToTail(
        remainingBytes: Int64,
        remainingFiles: Int
    ) -> Self? {
        guard remainingBytes > 0, remainingFiles > 0 else { return nil }
        return Self(
            maxBytes: min(maxBytes, remainingBytes),
            maxFiles: min(maxFiles, remainingFiles),
            scheduleDelaySeconds: scheduleDelaySeconds,
            minimumDatabaseLeaseSeconds: minimumDatabaseLeaseSeconds,
            throttleEveryBytes: throttleEveryBytes,
            throttleDelayMilliseconds: throttleDelayMilliseconds,
            maximumDurationSeconds: maximumDurationSeconds
        )
    }
}

/// Monotonic, testable state for the app's continuation schedule. Keeping the
/// deadline here prevents each slice's wall time from silently reducing the
/// intended sustained indexing rate.
public struct SkillUsageMaintenanceSchedule: Sendable, Equatable {
    public private(set) var phase: SkillUsageMaintenancePhase = .firstContinuation
    public private(set) var nextDueUptime: TimeInterval?

    public init() {}

    public mutating func resetDeadline() {
        nextDueUptime = nil
    }

    public func plan(
        isEnergyConstrained: Bool,
        isOnExternalPower: Bool = false,
        remainingBytes: Int64,
        remainingFiles: Int
    ) -> SkillUsageMaintenancePlan? {
        SkillUsageMaintenancePlan.recommended(
            phase: phase,
            isEnergyConstrained: isEnergyConstrained,
            isOnExternalPower: isOnExternalPower
        ).clampedToTail(
            remainingBytes: remainingBytes,
            remainingFiles: remainingFiles
        )
    }

    /// A deferred lease never materialized the reusable catalog, so it must
    /// not advance to the larger watcher-armed phase.
    public mutating func recordCompletion(
        wasDeferred: Bool,
        startedAtUptime: TimeInterval? = nil
    ) {
        guard !wasDeferred else { return }
        // Timer tolerance can deliver this slice late. Anchor the next lease
        // interval to its actual start, not the earlier planned deadline.
        if let startedAtUptime { nextDueUptime = startedAtUptime }
        phase = .watcherArmedCatchUp
    }

    /// Returns the delay until the next absolute deadline. After a completed
    /// slice, the next deadline advances from its recorded start rather than
    /// from completion time; if work overran the cadence, the delay bottoms at
    /// zero rather than drifting every subsequent slice.
    public mutating func delayBeforeNextRun(
        plan: SkillUsageMaintenancePlan,
        nowUptime: TimeInterval
    ) -> TimeInterval {
        let due = nextDueUptime.map { max($0 + plan.scheduleDelaySeconds, nowUptime) }
            ?? nowUptime + plan.scheduleDelaySeconds
        nextDueUptime = due
        return max(0, due - nowUptime)
    }
}
