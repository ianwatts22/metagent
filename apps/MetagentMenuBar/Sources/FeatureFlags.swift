import Foundation

enum AppFeatureFlags {
    static let previewFeaturesKey = "metagent.preview-features.v1"

    static func previewFeaturesEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: previewFeaturesKey)
    }
}
