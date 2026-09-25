import CryptoKit
import Darwin
import Foundation
import Security

/// Deliberately separate from the general MCP inspector and any chat connector credentials.
/// This is a local, manually initiated transport proof, not a publisher.
public enum NotionOAuthProof {
    public static let endpoint = URL(string: "https://mcp.notion.com/mcp")!
    public static let redirect = URL(string: "http://127.0.0.1:8765/callback")!
    private static let metadataURL = URL(string: "https://mcp.notion.com/.well-known/oauth-authorization-server")!
    private static let keychain = ProofKeychain(client: SystemProofKeychainClient())

    public struct Connection: Codable, Sendable {
        public let clientID: String
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date
        public let workspaceID: String?
        public let userID: String?
    }

    private struct Pending: Codable {
        let clientID: String
        let verifier: String
        let state: String
        let expiresAt: Date
    }

    private struct Metadata: Decodable {
        let issuer: String
        let authorization_endpoint: String
        let token_endpoint: String
        let registration_endpoint: String
        let code_challenge_methods_supported: [String]
    }

    private struct Registration: Decodable { let client_id: String }

    private struct Token: Decodable {
        let access_token: String
        let refresh_token: String?
        let token_type: String
        let expires_in: TimeInterval
        let workspace_id: String?
        let user_id: String?
    }

    public enum ProofError: LocalizedError {
        case invalidMetadata, invalidResponse, pendingExpired, invalidCallback, noConnection
        case authenticationFailed, randomFailure, keychainAccessRequired(OSStatus)
        case keychainFailure(OSStatus), lockFailure(Int32), networkFailure(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidMetadata: "Notion OAuth metadata did not satisfy the expected HTTPS and PKCE contract."
            case .invalidResponse: "Notion returned an incomplete OAuth response."
            case .pendingExpired: "The pending Notion sign-in expired. Start again."
            case .invalidCallback: "The callback URL or state did not match the pending Notion sign-in."
            case .noConnection: "No standalone Notion connection is stored. Run notion proof start first."
            case .authenticationFailed: "Notion authentication failed. Start a new sign-in."
            case .randomFailure: "Secure random generation failed."
            case .keychainAccessRequired(let code):
                "This metagent helper cannot access its saved Notion credential without a macOS Keychain prompt (OSStatus \(code)). Nothing was removed. Use a consistently signed helper for future sessions; review the existing item's access in Keychain Access before any one-time migration or reauthorization."
            case .keychainFailure(let code): "Keychain operation failed (OSStatus \(code))."
            case .lockFailure(let code): "Notion refresh lock failed (errno \(code))."
            case .networkFailure(let status): "Notion OAuth request failed (HTTP \(status)); response body was withheld."
            }
        }
    }

    private static func randomURLSafe() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ProofError.randomFailure
        }
        return Data(bytes).base64URLEncoded
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    static func isInvalidGrant(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["error"] as? String == "invalid_grant"
    }

    static func requiredRotatedRefreshToken(_ token: String?) throws -> String {
        guard let token, !token.isEmpty else { throw ProofError.invalidResponse }
        return token
    }

    static func rotatedConnection(from data: Data, current: Connection, now: Date = Date()) throws -> Connection {
        guard let token = try? JSONDecoder().decode(Token.self, from: data),
              token.token_type.lowercased() == "bearer", !token.access_token.isEmpty,
              token.expires_in > 0 else { throw ProofError.invalidResponse }
        let refresh = try requiredRotatedRefreshToken(token.refresh_token)
        return Connection(clientID: current.clientID, accessToken: token.access_token,
                          refreshToken: refresh, expiresAt: now.addingTimeInterval(token.expires_in),
                          workspaceID: current.workspaceID, userID: current.userID)
    }

    public static func validateCallback(_ callback: URL, expectedState: String) throws -> String {
        guard callback.scheme == redirect.scheme, callback.host == redirect.host,
              callback.port == redirect.port, callback.path == redirect.path,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
              state == expectedState,
              components.queryItems?.first(where: { $0.name == "error" }) == nil,
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { throw ProofError.invalidCallback }
        return code
    }

    private static func validatedURL(_ raw: String, path: String) throws -> URL {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "mcp.notion.com",
              url.path == path, url.user == nil, url.password == nil, url.query == nil,
              url.fragment == nil else { throw ProofError.invalidMetadata }
        return url
    }

    private static func metadata(session: URLSession) async throws -> (Metadata, URL, URL, URL) {
        let (data, response) = try await session.data(from: metadataURL)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ProofError.invalidMetadata
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard metadata.issuer == "https://mcp.notion.com",
              metadata.code_challenge_methods_supported.contains("S256") else {
            throw ProofError.invalidMetadata
        }
        return (metadata,
                try validatedURL(metadata.authorization_endpoint, path: "/authorize"),
                try validatedURL(metadata.token_endpoint, path: "/token"),
                try validatedURL(metadata.registration_endpoint, path: "/register"))
    }

    private static func request(_ url: URL, body: Data, contentType: String, session: URLSession,
                                detectsInvalidGrant: Bool = false) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProofError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if detectsInvalidGrant && isInvalidGrant(data) { throw ProofError.authenticationFailed }
            throw ProofError.networkFailure(response.statusCode)
        }
        return data
    }

    private static func form(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map(URLQueryItem.init(name:value:))
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    /// Registers an independent public OAuth client. Only the authorization URL is returned.
    public static func start(session: URLSession = .shared) async throws -> URL {
        let (_, authorize, _, register) = try await metadata(session: session)
        let registration = [
            "client_name": "Metagent Notion transport proof",
            "redirect_uris": [redirect.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ] as [String: Any]
        let body = try JSONSerialization.data(withJSONObject: registration)
        let data = try await request(register, body: body, contentType: "application/json", session: session)
        let client = try JSONDecoder().decode(Registration.self, from: data)
        guard !client.client_id.isEmpty else { throw ProofError.invalidResponse }
        let verifier = try randomURLSafe()
        let state = try randomURLSafe()
        let lock = try RefreshLock.acquire()
        defer { lock.release() }
        try keychain.save(Pending(clientID: client.client_id, verifier: verifier, state: state,
                                  expiresAt: Date().addingTimeInterval(600)), account: "pending")
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.client_id),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }

    /// Callback is consumed from stdin by the CLI; it must never be passed as a command argument.
    public static func finish(callback: URL, session: URLSession = .shared) async throws -> Connection {
        let lock = try RefreshLock.acquire()
        defer { lock.release() }
        guard let pending: Pending = try keychain.load(account: "pending") else { throw ProofError.pendingExpired }
        guard pending.expiresAt > Date() else {
            try keychain.delete(account: "pending")
            throw ProofError.pendingExpired
        }
        let code = try validateCallback(callback, expectedState: pending.state)
        let (_, _, tokenEndpoint, _) = try await metadata(session: session)
        let data = try await request(tokenEndpoint, body: form([
            "grant_type": "authorization_code", "code": code, "client_id": pending.clientID,
            "redirect_uri": redirect.absoluteString, "code_verifier": pending.verifier
        ]), contentType: "application/x-www-form-urlencoded", session: session)
        let token = try JSONDecoder().decode(Token.self, from: data)
        guard token.token_type.lowercased() == "bearer", !token.access_token.isEmpty,
              let refresh = token.refresh_token, !refresh.isEmpty, token.expires_in > 0 else {
            throw ProofError.invalidResponse
        }
        let connection = Connection(clientID: pending.clientID, accessToken: token.access_token,
                                    refreshToken: refresh, expiresAt: Date().addingTimeInterval(token.expires_in),
                                    workspaceID: token.workspace_id, userID: token.user_id)
        try keychain.save(connection, account: "connection")
        try keychain.delete(account: "pending")
        return connection
    }

    public static func connection(session: URLSession = .shared) async throws -> Connection {
        guard let stored: Connection = try keychain.load(account: "connection") else { throw ProofError.noConnection }
        guard stored.expiresAt <= Date().addingTimeInterval(60) else { return stored }
        // Every Notion refresh rotates the credential. Serialize across CLI processes and
        // re-read after taking the lock so a waiting process never replays a retired token.
        let lock = try RefreshLock.acquire()
        defer { lock.release() }
        guard let current: Connection = try keychain.load(account: "connection") else { throw ProofError.noConnection }
        guard current.expiresAt <= Date().addingTimeInterval(60) else { return current }
        let (_, _, tokenEndpoint, _) = try await metadata(session: session)
        let data: Data
        do {
            data = try await request(tokenEndpoint, body: form([
                "grant_type": "refresh_token", "refresh_token": current.refreshToken,
                "client_id": current.clientID
            ]), contentType: "application/x-www-form-urlencoded", session: session,
                               detectsInvalidGrant: true)
        } catch ProofError.authenticationFailed {
            try keychain.delete(account: "connection")
            throw ProofError.authenticationFailed
        }
        let updated: Connection
        do {
            updated = try rotatedConnection(from: data, current: current)
        } catch {
            // A 2xx response may have consumed the old refresh token. Never replay it.
            try keychain.delete(account: "connection")
            throw ProofError.invalidResponse
        }
        try keychain.save(updated, account: "connection")
        return updated
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct RefreshLock {
    private let descriptor: Int32

    static func acquire() throws -> RefreshLock {
        // Resolve macOS's per-user temp root independently of TMPDIR so CLI processes
        // and the app always coordinate on the same lock. No credential is written here.
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { throw NotionOAuthProof.ProofError.lockFailure(errno) }
        var bytes = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, length) > 0 else {
            throw NotionOAuthProof.ProofError.lockFailure(errno)
        }
        let directory = String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let path = (directory as NSString).appendingPathComponent("metagent-notion-refresh.lock")
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NotionOAuthProof.ProofError.lockFailure(errno) }
        var status = flock(descriptor, LOCK_EX)
        while status != 0 && errno == EINTR { status = flock(descriptor, LOCK_EX) }
        guard status == 0 else {
            let code = errno
            close(descriptor)
            throw NotionOAuthProof.ProofError.lockFailure(code)
        }
        return RefreshLock(descriptor: descriptor)
    }

    func release() {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

protocol ProofKeychainClient: Sendable {
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func load(_ query: [String: Any]) -> (OSStatus, Data?)
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemProofKeychainClient: ProofKeychainClient {
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func load(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

struct ProofKeychain<Client: ProofKeychainClient>: Sendable {
    private let service = "com.metagent.notion-transport-proof"
    private let client: Client

    init(client: Client) { self.client = client }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         // Request no UI for each operation. The CLI also disables Keychain UI
         // process-wide before these legacy-keychain calls.
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    private func failure(_ status: OSStatus) -> NotionOAuthProof.ProofError {
        switch status {
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled:
            return .keychainAccessRequired(status)
        default:
            return .keychainFailure(status)
        }
    }

    func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = query(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = client.update(query, attributes: update)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure(status) }
        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let inserted = client.add(addition)
        guard inserted == errSecSuccess else { throw failure(inserted) }
    }

    func load<T: Decodable>(account: String) throws -> T? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = client.load(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data else { throw NotionOAuthProof.ProofError.keychainFailure(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func delete(account: String) throws {
        let status = client.delete(query(account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure(status)
        }
    }
}
