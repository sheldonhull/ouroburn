import CryptoKit
import Foundation
import Network

/// OAuth 2.0 Authorization Code Flow with PKCE (RFC 7636) against Anthropic's Claude
/// authentication, mirroring `claude-proxy/internal/oauth/login.go`. Constants are
/// reproduced from the Claude Code CLI so the issued bearer is accepted on
/// `/api/oauth/usage` (which uses the same scope set).
enum OAuthLogin {
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let scopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    static let codeChallengeMethod = "S256"
    static let callbackPath = "/callback"
    static let tokenHTTPTimeout: TimeInterval = 15

    enum LoginError: Error, CustomStringConvertible {
        case listenerFailed(String)
        case stateMismatch
        case providerError(String)
        case noCode
        case tokenExchangeFailed(Int, String)
        case decodeFailed
        case emptyAccessToken
        case cancelled

        var description: String {
            switch self {
            case let .listenerFailed(reason): "local listener failed: \(reason)"
            case .stateMismatch: "OAuth state mismatch"
            case let .providerError(msg): "OAuth provider error: \(msg)"
            case .noCode: "no authorization code received"
            case let .tokenExchangeFailed(status, body): "token exchange HTTP \(status): \(body.prefix(200))"
            case .decodeFailed: "token response could not be decoded"
            case .emptyAccessToken: "token endpoint returned empty access_token"
            case .cancelled: "login cancelled"
            }
        }
    }

    /// Opens a PKCE flow: starts a local listener on a random loopback port, builds the
    /// authorize URL the caller should open in the browser, and returns a continuation that
    /// resolves once the user finishes login (or times out).
    static func startLogin() async throws -> (authURL: URL, completion: () async throws -> StoredCredential) {
        let verifier = generateRandomBase64URL(byteCount: 32)
        let challenge = sha256Base64URL(of: verifier)
        let state = generateRandomBase64URL(byteCount: 32)

        let server = try CallbackServer(state: state)
        let port = try await server.start()
        let redirectURI = "http://localhost:\(port)\(callbackPath)"

        guard let authURL = buildAuthorizeURL(redirectURI: redirectURI, state: state, challenge: challenge) else {
            await server.shutdown()
            throw LoginError.listenerFailed("authorize URL build failed")
        }

        Log.info(Log.app, "OAuth login starting (callback port \(port))")

        let completion: () async throws -> StoredCredential = {
            defer { Task { await server.shutdown() } }
            let code = try await server.awaitCode()
            let token = try await exchangeCode(code: code, verifier: verifier, redirectURI: redirectURI, state: state)
            return token
        }
        return (authURL, completion)
    }

    /// Refresh an expired (or near-expired) credential by trading the refresh token for a new
    /// access token. Returns the freshly-stamped credential the caller should persist.
    static func refresh(credential: StoredCredential) async throws -> StoredCredential {
        guard !credential.refreshToken.isEmpty else { throw LoginError.emptyAccessToken }
        let payload: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": credential.refreshToken,
            "client_id": clientID
        ]
        let response = try await postJSON(URL(string: tokenURL)!, payload: payload)
        return try parseTokenResponse(response)
    }

    private static func exchangeCode(
        code: String,
        verifier: String,
        redirectURI: String,
        state: String
    ) async throws -> StoredCredential {
        let payload: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "state": state
        ]
        let response = try await postJSON(URL(string: tokenURL)!, payload: payload)
        return try parseTokenResponse(response)
    }

    private static func postJSON(_ url: URL, payload: [String: String]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: tokenHTTPTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LoginError.tokenExchangeFailed(-1, "")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw LoginError.tokenExchangeFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func parseTokenResponse(_ data: Data) throws -> StoredCredential {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { throw LoginError.decodeFailed }
        guard let access = dict["access_token"] as? String, !access.isEmpty else {
            throw LoginError.emptyAccessToken
        }
        let refresh = (dict["refresh_token"] as? String) ?? ""
        let expiresAt: Date = if let absolute = dict["expires_at"] as? Double, absolute > 0 {
            Date(timeIntervalSince1970: absolute / 1000)
        } else if let seconds = dict["expires_in"] as? Double, seconds > 0 {
            Date().addingTimeInterval(seconds)
        } else {
            Date().addingTimeInterval(3600)
        }
        return StoredCredential(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    private static func buildAuthorizeURL(redirectURI: String, state: String, challenge: String) -> URL? {
        var components = URLComponents(string: authorizeURL)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: codeChallengeMethod),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    private static func generateRandomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func sha256Base64URL(of input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return Data(digest).base64URLEncoded()
    }
}

/// Tokens persisted to the keychain after a successful login.
struct StoredCredential: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt }
    func expiresWithin(_ interval: TimeInterval) -> Bool {
        Date().addingTimeInterval(interval) >= expiresAt
    }
}

/// Persists `StoredCredential` values to the macOS keychain under a single account entry.
enum OAuthCredentialStore {
    private static let account = SecretsAccount.ouroburnOAuth

    static func load() -> StoredCredential? {
        guard let raw = Keychain.read(account: account),
              let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredCredential.self, from: data)
    }

    static func save(_ credential: StoredCredential) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(credential),
              let raw = String(data: data, encoding: .utf8) else { return }
        Keychain.write(account: account, value: raw)
    }

    static func clear() {
        Keychain.delete(account: account)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Loopback HTTP listener that accepts a single OAuth callback request, validates the
/// state parameter, and surfaces the authorization code. Only the GET line is parsed —
/// no full HTTP parser is needed since the OAuth provider sends a deterministic redirect.
private actor CallbackServer {
    private let state: String
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?

    init(state: String) throws {
        self.state = state
    }

    /// Bind to 127.0.0.1 on a random ephemeral port and return that port.
    func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw OAuthLogin.LoginError.listenerFailed(error.localizedDescription)
        }
        self.listener = listener

        let portContinuation = ContinuationBox<Int>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    portContinuation.resume(.success(Int(port)))
                }
            case let .failed(error):
                portContinuation.resume(.failure(OAuthLogin.LoginError.listenerFailed(error.localizedDescription)))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))

        return try await portContinuation.value()
    }

    /// Suspends until the callback handler resolves with a code (or error).
    func awaitCode() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
        }
    }

    func shutdown() {
        listener?.cancel()
        listener = nil
        continuation?.resume(throwing: OAuthLogin.LoginError.cancelled)
        continuation = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            Task { await self.process(data: data ?? Data(), connection: connection) }
        }
    }

    private func process(data: Data, connection: NWConnection) {
        let request = String(data: data, encoding: .utf8) ?? ""
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? request
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(connection: connection, html: "<h2>Login failed</h2><p>Bad request.</p>")
            finish(.failure(OAuthLogin.LoginError.noCode))
            return
        }
        let path = String(parts[1])
        guard let url = URL(string: "http://localhost\(path)") else {
            respond(connection: connection, html: "<h2>Login failed</h2><p>Bad URL.</p>")
            finish(.failure(OAuthLogin.LoginError.noCode))
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let lookup = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })

        if let providerError = lookup["error"] {
            let desc = lookup["error_description"] ?? providerError
            respond(connection: connection, html: "<h2>Login failed</h2><p>\(desc)</p>")
            finish(.failure(OAuthLogin.LoginError.providerError(desc)))
            return
        }
        guard lookup["state"] == state else {
            respond(connection: connection, html: "<h2>Login failed</h2><p>State mismatch.</p>")
            finish(.failure(OAuthLogin.LoginError.stateMismatch))
            return
        }
        guard let code = lookup["code"], !code.isEmpty else {
            respond(connection: connection, html: "<h2>Login failed</h2><p>No code.</p>")
            finish(.failure(OAuthLogin.LoginError.noCode))
            return
        }
        respond(connection: connection, html: "<h2>Login successful</h2><p>You can close this tab.</p>")
        finish(.success(code))
    }

    private func respond(connection: NWConnection, html: String) {
        let body = "<html><body>\(html)</body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case let .success(code): continuation.resume(returning: code)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}

/// Threadsafe continuation handoff used while NWListener transitions through state callbacks.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    private var pending: Result<T, Error>?

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            lock.lock()
            if let pending {
                lock.unlock()
                switch pending {
                case let .success(value): cont.resume(returning: value)
                case let .failure(error): cont.resume(throwing: error)
                }
                return
            }
            self.continuation = cont
            lock.unlock()
        }
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            switch result {
            case let .success(value): continuation.resume(returning: value)
            case let .failure(error): continuation.resume(throwing: error)
            }
        } else {
            pending = result
            lock.unlock()
        }
    }
}
