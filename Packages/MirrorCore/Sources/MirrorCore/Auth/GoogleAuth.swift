import Foundation

/// Google sign-in (OAuth 2.0 installed-app flow with PKCE) and access-token management.
///
/// Access tokens live in memory only; the refresh token lives in the `TokenStore`.
public actor GoogleAuth: AccessTokenProvider {
  private struct CachedToken {
    var value: String
    var expiresAt: Date
  }

  private struct TokenResponse: Decodable {
    var accessToken: String
    var expiresIn: Double
    var refreshToken: String?
  }

  private struct ErrorResponse: Decodable {
    var error: String?
  }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  private let config: OAuthClientConfig
  private let store: any TokenStore
  private let session: URLSession
  private let now: @Sendable () -> Date
  private let refreshMargin: TimeInterval

  private var cached: CachedToken?
  private var inFlightRefresh: Task<String, any Error>?

  public init(
    config: OAuthClientConfig,
    store: any TokenStore,
    session: URLSession = .shared,
    now: @escaping @Sendable () -> Date = { Date() },
    refreshMargin: TimeInterval = 60
  ) {
    self.config = config
    self.store = store
    self.session = session
    self.now = now
    self.refreshMargin = refreshMargin
  }

  public var isSignedIn: Bool {
    get async { (try? await store.loadRefreshToken()) != nil }
  }

  /// Runs the browser flow. `openBrowser` is called once with the Google consent URL.
  public func signIn(openBrowser: @Sendable (URL) async -> Void) async throws {
    let pkce = PKCE.generate()
    let state = PKCE.randomState()
    let server = try LoopbackRedirectServer()
    do {
      let port = try await server.start()
      let url = AuthorizationURL.make(
        config: config, port: port, state: state, codeChallenge: pkce.challenge)
      let waiting = Task { try await server.waitForCode(expectedState: state) }
      await openBrowser(url)
      let code = try await withTaskCancellationHandler {
        try await waiting.value
      } onCancel: {
        waiting.cancel()
      }
      await server.stop()
      try await completeSignIn(
        code: code, codeVerifier: pkce.verifier,
        redirectURI: AuthorizationURL.redirectURI(port: port))
    } catch {
      await server.stop()
      throw error
    }
  }

  public func signOut() async throws {
    cached = nil
    try await store.deleteRefreshToken()
  }

  public func accessToken() async throws -> String {
    if let cached, cached.expiresAt.timeIntervalSince(now()) > refreshMargin {
      return cached.value
    }
    // Concurrent callers share one refresh; Google may rotate tokens, and parallel
    // refreshes would waste requests and race on the stored value.
    if let inFlightRefresh { return try await inFlightRefresh.value }
    let task = Task {
      defer { inFlightRefresh = nil }
      return try await refresh()
    }
    inFlightRefresh = task
    return try await task.value
  }

  public func invalidateAccessToken() {
    cached = nil
  }

  func completeSignIn(code: String, codeVerifier: String, redirectURI: String) async throws {
    let response = try await requestTokens([
      "grant_type": "authorization_code",
      "code": code,
      "code_verifier": codeVerifier,
      "redirect_uri": redirectURI,
    ])
    guard let refreshToken = response.refreshToken else { throw AuthError.missingRefreshToken }
    try await store.saveRefreshToken(refreshToken)
    remember(response)
  }

  private func refresh() async throws -> String {
    guard let refreshToken = try await store.loadRefreshToken() else {
      cached = nil
      throw AuthError.signedOut
    }
    do {
      let response = try await requestTokens([
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
      ])
      if let rotated = response.refreshToken, rotated != refreshToken {
        try await store.saveRefreshToken(rotated)
      }
      return remember(response)
    } catch AuthError.tokenEndpoint(_, "invalid_grant") {
      // The grant was revoked or expired; retrying can't help, so go to signed-out.
      try? await store.deleteRefreshToken()
      cached = nil
      throw AuthError.signedOut
    }
  }

  @discardableResult
  private func remember(_ response: TokenResponse) -> String {
    cached = CachedToken(
      value: response.accessToken, expiresAt: now().addingTimeInterval(response.expiresIn))
    return response.accessToken
  }

  private func requestTokens(_ fields: [String: String]) async throws -> TokenResponse {
    var request = URLRequest(url: config.tokenURI)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let all = fields.merging([
      "client_id": config.clientID, "client_secret": config.clientSecret,
    ]) { $1 }
    request.httpBody = Data(Self.formEncode(all).utf8)

    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let error = try? Self.decoder.decode(ErrorResponse.self, from: data).error
      throw AuthError.tokenEndpoint(status: status, error: error)
    }
    guard let parsed = try? Self.decoder.decode(TokenResponse.self, from: data) else {
      throw AuthError.malformedTokenResponse
    }
    return parsed
  }

  private static func formEncode(_ fields: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields.sorted { $0.key < $1.key }.map { key, value in
      let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
      return "\(key)=\(encoded)"
    }.joined(separator: "&")
  }
}
