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
final class UpdaterModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var presentationDismissalRequest: UInt = 0

    /// False while `SUFeedURL` is still the checked-in placeholder.
    let isConfigured: Bool

    private var controller: SPUStandardUpdaterController!
    private var observation: AnyCancellable?
    private var presentationDismissalRequests = UpdatePresentationDismissalRequests()

    override init() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let startupPolicy = AppUpdateStartupPolicy(feedURL: feedURL)
        isConfigured = startupPolicy.isConfigured
        startupPolicy.repairLegacyAutomaticChecksPreference(in: .standard)

        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
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
        guard isConfigured, canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    /// Sparkle can install from either a user-initiated or background check.
    /// Close app-owned sheets before its installer asks the app to terminate so
    /// no presentation remains stranded in front of the update UI.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        presentationDismissalRequests.willInstallUpdate()
        publishPresentationDismissalRequest()
    }

    /// A final backstop for resumed updates that reach the relaunch boundary.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        presentationDismissalRequests.willRelaunch()
        publishPresentationDismissalRequest()
    }

    private func publishPresentationDismissalRequest() {
        presentationDismissalRequest = presentationDismissalRequests.value
    }
}

/// A tiny seam around Sparkle's delegate callbacks. Keeping the counter separate
/// lets regression tests cover both lifecycle boundaries without constructing
/// Sparkle's framework-owned updater and appcast objects.
struct UpdatePresentationDismissalRequests {
    private(set) var value: UInt = 0

    mutating func willInstallUpdate() {
        value &+= 1
    }

    mutating func willRelaunch() {
        value &+= 1
    }
}

/// The installed version, as the user would read it in About: marketing version
/// first, build number beside it because that is what Sparkle actually compares.
/// Dev builds have no meaningful version, so they name their commit instead —
/// the one identifier that says exactly which code is running.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        if let commit = info?["MetagentBuildCommit"] as? String, !commit.isEmpty {
            return "Version \(short) · \(commit)"
        }
        return "Version \(short) (\(build))"
    }
}
