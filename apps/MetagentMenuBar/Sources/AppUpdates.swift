import Combine
import Foundation
import MetagentCore
import Sparkle
import SwiftUI

/// Sparkle's updater, wrapped so SwiftUI can observe it.
///
/// The feed URL and public key ship as placeholders until a release is actually
/// configured, so an unconfigured build reports that plainly and never retries a
/// placeholder URL in the background.
@MainActor
final class UpdaterModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    /// False while `SUFeedURL` is still the checked-in placeholder.
    let isConfigured: Bool

    private let controller: SPUStandardUpdaterController
    private var observation: AnyCancellable?

    init() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let startupPolicy = AppUpdateStartupPolicy(feedURL: feedURL)
        isConfigured = startupPolicy.isConfigured
        startupPolicy.repairLegacyAutomaticChecksPreference(in: .standard)

        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        if isConfigured {
            controller.startUpdater()
        }

        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .removeDuplicates()
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// The installed version, as the user would read it in About: marketing version
/// first, build number beside it because that is what Sparkle actually compares.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }
}
