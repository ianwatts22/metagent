import Foundation

/// Startup decisions that must be made before Sparkle constructs its updater.
public struct AppUpdateStartupPolicy: Sendable, Equatable {
    static let automaticChecksKey = "SUEnableAutomaticChecks"
    static let legacyPreferenceRepairKey = "MetagentDidRepairUnconfiguredSparklePreference"

    public let isConfigured: Bool

    public init(feedURL: String?) {
        isConfigured = !(feedURL?.contains("REPLACE_ME") ?? true)
    }

    /// Repairs the one preference older unconfigured builds could write.
    ///
    /// Metagent has always declared automatic checks in Info.plist and has no
    /// user-facing toggle for them. Removing only the old persisted `false`
    /// restores that declared default. The marker makes this a one-time repair,
    /// so a future user-facing preference remains respected.
    public func repairLegacyAutomaticChecksPreference(in defaults: UserDefaults) {
        guard isConfigured, !defaults.bool(forKey: Self.legacyPreferenceRepairKey) else {
            return
        }
        if defaults.object(forKey: Self.automaticChecksKey) as? Bool == false {
            defaults.removeObject(forKey: Self.automaticChecksKey)
        }
        defaults.set(true, forKey: Self.legacyPreferenceRepairKey)
    }
}
