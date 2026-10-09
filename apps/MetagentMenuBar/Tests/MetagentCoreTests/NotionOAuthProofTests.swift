import Foundation
import Security
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

    @Test func keychainQueriesNeverAllowAuthenticationUI() throws {
        let absent = RecordingKeychainClient(updateStatus: errSecItemNotFound,
                                             loadStatus: errSecItemNotFound,
                                             deleteStatus: errSecItemNotFound)
        let keychain = ProofKeychain(client: absent)
        try keychain.save(SampleCredential(value: "secret"), account: "connection")
        let loaded: SampleCredential? = try keychain.load(account: "connection")
        #expect(loaded == nil)
        try keychain.delete(account: "connection")

        let calls = absent.recordedCalls()
        #expect(calls.map(\.operation) == ["update", "add", "load", "delete"])
        for call in calls {
            #expect(call.query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
            #expect(call.query[kSecAttrService as String] as? String == "com.metagent.notion-transport-proof")
        }
        #expect(calls[1].query[kSecValueData as String] is Data)
    }

    @Test func keychainDenialNeverFallsBackToAddOrDelete() throws {
        for denied in [errSecInteractionNotAllowed, errSecInteractionRequired,
                       errSecAuthFailed, errSecUserCanceled] {
            let reader = RecordingKeychainClient(loadStatus: denied)
            let readKeychain = ProofKeychain(client: reader)
            do {
                let _: SampleCredential? = try readKeychain.load(account: "connection")
                Issue.record("Expected Keychain access denial")
            } catch {
                #expect(accessRequiredStatus(error) == denied)
            }
            #expect(reader.recordedCalls().map(\.operation) == ["load"])

            let writer = RecordingKeychainClient(updateStatus: denied)
            let writeKeychain = ProofKeychain(client: writer)
            do {
                try writeKeychain.save(SampleCredential(value: "new"), account: "connection")
                Issue.record("Expected Keychain update denial")
            } catch {
                #expect(accessRequiredStatus(error) == denied)
            }
            #expect(writer.recordedCalls().map(\.operation) == ["update"])

            let deleter = RecordingKeychainClient(deleteStatus: denied)
            let deleteKeychain = ProofKeychain(client: deleter)
            do {
                try deleteKeychain.delete(account: "connection")
                Issue.record("Expected Keychain delete denial")
            } catch {
                #expect(accessRequiredStatus(error) == denied)
            }
            #expect(deleter.recordedCalls().map(\.operation) == ["delete"])
        }
    }

    private func accessRequiredStatus(_ error: Error) -> OSStatus? {
        guard case NotionOAuthProof.ProofError.keychainAccessRequired(let status) = error else { return nil }
        return status
    }
}

private struct SampleCredential: Codable {
    let value: String
}

private final class RecordingKeychainClient: ProofKeychainClient, @unchecked Sendable {
    struct Call {
        let operation: String
        let query: [String: Any]
    }

    private let updateStatus: OSStatus
    private let addStatus: OSStatus
    private let loadStatus: OSStatus
    private let deleteStatus: OSStatus
    private let lock = NSLock()
    private var calls: [Call] = []

    init(updateStatus: OSStatus = errSecSuccess, addStatus: OSStatus = errSecSuccess,
         loadStatus: OSStatus = errSecSuccess, deleteStatus: OSStatus = errSecSuccess) {
        self.updateStatus = updateStatus
        self.addStatus = addStatus
        self.loadStatus = loadStatus
        self.deleteStatus = deleteStatus
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        record("update", query)
        return updateStatus
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        record("add", attributes)
        return addStatus
    }

    func load(_ query: [String: Any]) -> (OSStatus, Data?) {
        record("load", query)
        return (loadStatus, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        record("delete", query)
        return deleteStatus
    }

    func recordedCalls() -> [Call] { lock.withLock { calls } }

    private func record(_ operation: String, _ query: [String: Any]) {
        lock.withLock { calls.append(Call(operation: operation, query: query)) }
    }
}
