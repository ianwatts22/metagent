import Foundation
import Testing
@testable import MetagentCore

@Suite("App update startup policy")
struct AppUpdatePolicyTests {
    @Test("starts only with a configured feed")
    func configurationDetection() {
        #expect(!AppUpdateStartupPolicy(feedURL: nil).isConfigured)
        #expect(!AppUpdateStartupPolicy(feedURL: "https://REPLACE_ME/appcast.xml").isConfigured)
        #expect(AppUpdateStartupPolicy(feedURL: "https://metagent.sh/appcast.xml").isConfigured)
    }

    @Test("configured feed repairs the legacy false preference once")
    func repairsLegacyFalseOnce() throws {
        try withTemporaryDefaults { defaults in
            defaults.set(false, forKey: AppUpdateStartupPolicy.automaticChecksKey)
            let policy = AppUpdateStartupPolicy(feedURL: "https://metagent.sh/appcast.xml")

            policy.repairLegacyAutomaticChecksPreference(in: defaults)

            #expect(defaults.object(forKey: AppUpdateStartupPolicy.automaticChecksKey) == nil)
            #expect(defaults.bool(forKey: AppUpdateStartupPolicy.legacyPreferenceRepairKey))

            defaults.set(false, forKey: AppUpdateStartupPolicy.automaticChecksKey)
            policy.repairLegacyAutomaticChecksPreference(in: defaults)
            #expect(defaults.object(forKey: AppUpdateStartupPolicy.automaticChecksKey) as? Bool == false)
        }
    }

    @Test("unconfigured feed leaves preferences untouched")
    func unconfiguredFeedDoesNotMigrate() throws {
        try withTemporaryDefaults { defaults in
            defaults.set(false, forKey: AppUpdateStartupPolicy.automaticChecksKey)

            AppUpdateStartupPolicy(feedURL: "https://REPLACE_ME/appcast.xml")
                .repairLegacyAutomaticChecksPreference(in: defaults)

            #expect(defaults.object(forKey: AppUpdateStartupPolicy.automaticChecksKey) as? Bool == false)
            #expect(!defaults.bool(forKey: AppUpdateStartupPolicy.legacyPreferenceRepairKey))
        }
    }

    private func withTemporaryDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "AppUpdatePolicyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileReadUnknown)
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
