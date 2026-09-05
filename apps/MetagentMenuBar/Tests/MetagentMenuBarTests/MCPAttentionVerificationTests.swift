import MetagentCore
import Testing
@testable import MetagentMenuBar

private func snapshot(_ state: MCPConnectionState) -> MCPHealthSnapshot {
    MCPHealthSnapshot(servers: [MCPServerHealth(client: .codex, name: "test", state: state, detail: "")])
}

@Test func mcpMissingVerificationContextStaysActionableWithoutChangingEvidence() {
    let original = snapshot(.needsSignIn).servers[0]
    let evidence = MCPHealthSnapshot()
    let presented = mcpAttentionSnapshot(evidence, retainedServers: [original.id: original])
    #expect(presented.attention.map(\.id) == [original.id])
    #expect(evidence.servers.isEmpty)
    let healthy = mcpAttentionSnapshot(snapshot(.configured), retainedServers: [original.id: original])
    #expect(healthy.servers.count == 1)
    #expect(healthy.attention.isEmpty)
}

@Test func mcpVerificationRejectsPreActionScan() {
    var verification = MCPAttentionVerification()
    let oldGeneration = verification.generation
    verification.begin(serverID: "codex:test")
    for _ in 0..<5 {
        #expect(verification.consume(snapshot(.needsSignIn), generation: oldGeneration).isEmpty)
    }
    #expect(verification.pendingIDs == ["codex:test"])
    #expect(verification.consume(snapshot(.configured), generation: oldGeneration).isEmpty)
    #expect(verification.pendingIDs == ["codex:test"])
}

@Test func mcpVerificationGraceThenSuccess() {
    var verification = MCPAttentionVerification()
    verification.begin(serverID: "codex:test")
    #expect(verification.consume(snapshot(.needsSignIn), generation: verification.generation).isEmpty)
    #expect(verification.pendingIDs == ["codex:test"])
    #expect(verification.consume(snapshot(.configured), generation: verification.generation).isEmpty)
    #expect(verification.pendingIDs.isEmpty)
}

@Test func mcpVerificationBoundedFailureIncludesMissingEvidence() {
    var verification = MCPAttentionVerification()
    verification.begin(serverID: "codex:test")
    for _ in 0..<2 {
        #expect(verification.consume(MCPHealthSnapshot(), generation: verification.generation).isEmpty)
    }
    #expect(verification.consume(MCPHealthSnapshot(), generation: verification.generation) == ["codex:test"])
    #expect(verification.pendingIDs.isEmpty)
    #expect(verification.consume(snapshot(.needsSignIn), generation: verification.generation).isEmpty)
}

@Test func mcpVerificationNewActionResetsRetryBudget() {
    var verification = MCPAttentionVerification()
    verification.begin(serverID: "codex:test")
    let previousGeneration = verification.generation
    _ = verification.consume(snapshot(.needsSignIn), generation: previousGeneration)
    verification.begin(serverID: "codex:test")
    #expect(verification.consume(snapshot(.needsSignIn), generation: previousGeneration).isEmpty)
    for _ in 0..<2 {
        #expect(verification.consume(snapshot(.needsSignIn), generation: verification.generation).isEmpty)
    }
    #expect(verification.consume(snapshot(.needsSignIn), generation: verification.generation) == ["codex:test"])
}
