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
}
