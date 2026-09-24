import Foundation
import Testing
@testable import MetagentCore

@Suite("Standalone Notion OAuth proof")
struct NotionOAuthProofTests {
    @Test func pkceS256KnownVector() {
        // RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(NotionOAuthProof.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func callbackRequiresExactLoopbackAndState() throws {
        let valid = URL(string: "http://127.0.0.1:8765/callback?code=abc&state=expected")!
        #expect(try NotionOAuthProof.validateCallback(valid, expectedState: "expected") == "abc")
        let wrongState = URL(string: "http://127.0.0.1:8765/callback?code=abc&state=other")!
        #expect(throws: NotionOAuthProof.ProofError.self) {
            try NotionOAuthProof.validateCallback(wrongState, expectedState: "expected")
        }
        let wrongPort = URL(string: "http://127.0.0.1:8766/callback?code=abc&state=expected")!
        #expect(throws: NotionOAuthProof.ProofError.self) {
            try NotionOAuthProof.validateCallback(wrongPort, expectedState: "expected")
        }
        let denied = URL(string: "http://127.0.0.1:8765/callback?error=access_denied&state=expected")!
        #expect(throws: NotionOAuthProof.ProofError.self) {
            try NotionOAuthProof.validateCallback(denied, expectedState: "expected")
        }
    }

    @Test func refreshRequiresRotatedCredential() throws {
        #expect(try NotionOAuthProof.requiredRotatedRefreshToken("new") == "new")
        #expect(throws: NotionOAuthProof.ProofError.self) {
            try NotionOAuthProof.requiredRotatedRefreshToken(nil)
        }
        #expect(throws: NotionOAuthProof.ProofError.self) {
            try NotionOAuthProof.requiredRotatedRefreshToken("")
        }
    }

    @Test func onlyExplicitInvalidGrantIsTerminal() {
        #expect(NotionOAuthProof.isInvalidGrant(Data(#"{"error":"invalid_grant"}"#.utf8)))
        #expect(!NotionOAuthProof.isInvalidGrant(Data(#"{"error":"temporarily_unavailable"}"#.utf8)))
        #expect(!NotionOAuthProof.isInvalidGrant(Data("not json".utf8)))
    }

    @Test func refreshResponseRequiresCompleteRotatedPair() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let current = NotionOAuthProof.Connection(clientID: "client", accessToken: "old-access",
                                                  refreshToken: "old-refresh", expiresAt: now,
                                                  workspaceID: "workspace", userID: "user")
        let valid = Data(#"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}"#.utf8)
        let updated = try NotionOAuthProof.rotatedConnection(from: valid, current: current, now: now)
        #expect(updated.accessToken == "new-access")
        #expect(updated.refreshToken == "new-refresh")
        #expect(updated.expiresAt == now.addingTimeInterval(3600))
        #expect(updated.workspaceID == "workspace")

        let missingRefresh = Data(#"{"access_token":"new-access","token_type":"Bearer","expires_in":3600}"#.utf8)
        let emptyRefresh = Data(#"{"access_token":"new-access","refresh_token":"","token_type":"Bearer","expires_in":3600}"#.utf8)
        for response in [missingRefresh, emptyRefresh, Data("not json".utf8)] {
            #expect(throws: NotionOAuthProof.ProofError.self) {
                try NotionOAuthProof.rotatedConnection(from: response, current: current, now: now)
            }
        }
    }

    @Test func refreshLockSerializesWriters() throws {
        let first = try RefreshLock.acquire()
        let started = DispatchSemaphore(value: 0)
        let acquired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            guard let second = try? RefreshLock.acquire() else { return }
            acquired.signal()
            second.release()
        }
        #expect(started.wait(timeout: .now() + 2) == .success)
        #expect(acquired.wait(timeout: .now() + 0.05) == .timedOut)
        first.release()
        #expect(acquired.wait(timeout: .now() + 2) == .success)
    }
}
