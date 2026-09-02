import Foundation
import MetagentCore
import Testing
@testable import MetagentMenuBar

@Test func historyNavigationRequiresPreviewFeatures() {
    #expect(!PanelSection.visibleCases(previewFeaturesEnabled: false).contains(.history))
    #expect(PanelSection.visibleCases(previewFeaturesEnabled: true).contains(.history))
    #expect(PanelSection.visibleCases(previewFeaturesEnabled: false).contains(.overview))
}

@Test func loopbackMCPURLsAreRecognizedWithoutTreatingRemoteURLsAsLocal() throws {
    #expect(isLoopbackMCPURL(URL(string: "http://127.0.0.1:23373/v0/mcp")!))
    #expect(isLoopbackMCPURL(URL(string: "http://localhost:3000/mcp")!))
    #expect(!isLoopbackMCPURL(URL(string: "https://mcp.example.com/mcp")!))
}

@Test func beeperLoopbackMCPMapsToTheInstalledApplicationBundle() throws {
    let server = MCPServerHealth(
        client: .codex,
        name: "beeper",
        state: .needsSignIn,
        detail: "Sign-in required"
    )
    let endpoint = URL(string: "http://127.0.0.1:23373/v0/mcp")!

    let application = try #require(localMCPApplication(for: server, endpoint: endpoint))

    #expect(application.displayName == "Beeper")
    #expect(application.bundleIdentifier == "com.automattic.beeper.desktop")
}

@Test func unknownOrRemoteMCPsDoNotGuessAnApplication() throws {
    let server = MCPServerHealth(
        client: .codex,
        name: "unknown",
        state: .needsSignIn,
        detail: "Sign-in required"
    )

    #expect(localMCPApplication(
        for: server,
        endpoint: URL(string: "http://127.0.0.1:3000/mcp")!
    ) == nil)
    #expect(localMCPApplication(
        for: server,
        endpoint: URL(string: "https://mcp.example.com/mcp")!
    ) == nil)
}
