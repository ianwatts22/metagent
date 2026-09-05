import Foundation
import Testing
@testable import MetagentMenuBar

@Test func bothUpdaterBoundariesDismissNativeAuthenticationPresentations() async {
    let notificationCenter = NotificationCenter()
    await confirmation(expectedCount: 2) { dismissed in
        let observer = notificationCenter.addObserver(
            forName: .metagentDismissPresentations, object: nil, queue: nil
        ) { _ in dismissed() }
        defer { notificationCenter.removeObserver(observer) }
        var requests = UpdatePresentationDismissalRequests(notificationCenter: notificationCenter)
        requests.willInstallUpdate()
        requests.willRelaunch()
    }
}

@Test func willInstallUpdateRequestsPresentationDismissal() {
    var requests = UpdatePresentationDismissalRequests()

    requests.willInstallUpdate()

    #expect(requests.value == 1)
}

@Test func willRelaunchRequestsPresentationDismissal() {
    var requests = UpdatePresentationDismissalRequests()

    requests.willRelaunch()

    #expect(requests.value == 1)
}

@MainActor
@Test func settingsUpdateActionDismissesBeforeCheckingForUpdates() {
    var events: [String] = []

    performSettingsUpdateCheck(
        dismiss: { events.append("dismiss") },
        schedule: { action in action() },
        checkForUpdates: { events.append("check") }
    )

    #expect(events == ["dismiss", "check"])
}
