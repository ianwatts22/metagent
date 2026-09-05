import Foundation

public extension MetagentCore {
    /// Archive/plugin installers sometimes normalize mtimes to Unix 0 or 1.
    /// These are missing provenance, not evidence that a skill is decades old.
    /// Keep this specific to skill update dates; session timestamps use other rules.
    static func skillUpdateDate(_ timestamp: String?) -> Date? {
        guard let timestamp, let date = parseSkillUsageTimestamp(timestamp) else { return nil }
        return validSkillUpdateDate(date)
    }

    static func validSkillUpdateDate(_ date: Date) -> Date? {
        // Exclude the epoch day (including timezone-shifted sentinels) and
        // pre-epoch placeholders. Do not impose a rolling age cutoff.
        guard date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970 >= 86_400,
              date < Date.distantFuture else { return nil }
        return date
    }
}
