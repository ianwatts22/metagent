import Testing
@testable import MetagentMenuBar

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
