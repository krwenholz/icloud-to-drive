import Foundation
import Testing

@testable import MirrorCore

struct GoogleAuthTests {
  private func makeAuth(
    refreshToken: String? = "refresh-1", stub: HTTPStub,
    clock: TestClock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
  ) -> (GoogleAuth, InMemoryTokenStore, TestClock) {
    let store = InMemoryTokenStore(token: refreshToken)
    let auth = GoogleAuth(
      config: testConfig, store: store, session: stub.session, now: { clock.now })
    return (auth, store, clock)
  }

  @Test func codeExchangeParsesTokensAndStoresRefreshToken() async throws {
    let stub = HTTPStub()
    stub.enqueue(.json(200, tokenJSON(access: "at-1", refresh: "rt-1")))
    let (auth, store, _) = makeAuth(refreshToken: nil, stub: stub)

    try await auth.completeSignIn(
      code: "the-code", codeVerifier: "ver", redirectURI: "http://127.0.0.1:5555")

    let request = try #require(stub.requests.first)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString == "https://oauth2.googleapis.com/token")
    #expect(request.header("Content-Type") == "application/x-www-form-urlencoded")
    #expect(
      formFields(request.body) == [
        "grant_type": "authorization_code", "code": "the-code", "code_verifier": "ver",
        "redirect_uri": "http://127.0.0.1:5555", "client_id": "client-id",
        "client_secret": "client-secret",
      ])
    #expect(await store.loadRefreshToken() == "rt-1")
    #expect(try await auth.accessToken() == "at-1")
    #expect(stub.requests.count == 1)
    #expect(await auth.isSignedIn)
  }

  @Test func exchangeWithoutRefreshTokenFails() async throws {
    let stub = HTTPStub()
    stub.enqueue(.json(200, tokenJSON(access: "at-1")))
    let (auth, _, _) = makeAuth(refreshToken: nil, stub: stub)
    await #expect(throws: AuthError.missingRefreshToken) {
      try await auth.completeSignIn(code: "c", codeVerifier: "v", redirectURI: "r")
    }
  }

  @Test func malformedTokenResponseThrows() async throws {
    let stub = HTTPStub()
    stub.enqueue(.json(200, #"{"nope":true}"#))
    let (auth, _, _) = makeAuth(stub: stub)
    await #expect(throws: AuthError.malformedTokenResponse) { try await auth.accessToken() }
  }

  @Test func freshTokenIsReusedAndNearExpiryRefreshes() async throws {
    let stub = HTTPStub()
    stub.enqueue(
      .json(200, tokenJSON(access: "at-1", expiresIn: 3600)),
      .json(200, tokenJSON(access: "at-2", expiresIn: 3600)))
    let (auth, _, clock) = makeAuth(stub: stub)

    #expect(try await auth.accessToken() == "at-1")
    let refresh = try #require(stub.requests.first)
    #expect(
      formFields(refresh.body) == [
        "grant_type": "refresh_token", "refresh_token": "refresh-1", "client_id": "client-id",
        "client_secret": "client-secret",
      ])

    clock.advance(by: 3000)
    #expect(try await auth.accessToken() == "at-1")
    #expect(stub.requests.count == 1)

    clock.advance(by: 541)  // 59s left, inside the 60s margin
    #expect(try await auth.accessToken() == "at-2")
    #expect(stub.requests.count == 2)
  }

  @Test func invalidateForcesRefresh() async throws {
    let stub = HTTPStub()
    stub.enqueue(.json(200, tokenJSON(access: "at-1")), .json(200, tokenJSON(access: "at-2")))
    let (auth, _, _) = makeAuth(stub: stub)
    #expect(try await auth.accessToken() == "at-1")
    await auth.invalidateAccessToken()
    #expect(try await auth.accessToken() == "at-2")
  }

  @Test func rotatedRefreshTokenIsSaved() async throws {
    let stub = HTTPStub()
    stub.enqueue(.json(200, tokenJSON(access: "at-1", refresh: "rotated")))
    let (auth, store, _) = makeAuth(stub: stub)
    _ = try await auth.accessToken()
    #expect(await store.loadRefreshToken() == "rotated")
  }

  @Test func concurrentCallersShareOneRefresh() async throws {
    let stub = HTTPStub()
    stub.respond { _ in .json(200, tokenJSON(access: "shared")) }
    let (auth, _, _) = makeAuth(stub: stub)
    let tokens = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<8 { group.addTask { try await auth.accessToken() } }
      return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(tokens == Array(repeating: "shared", count: 8))
    #expect(stub.requests.count == 1)
  }

  @Test func invalidGrantSignsOutWithoutRetry() async throws {
    let stub = HTTPStub()
    stub.enqueue(
      .json(400, #"{"error":"invalid_grant","error_description":"Token has been expired"}"#))
    let (auth, store, _) = makeAuth(stub: stub)

    await #expect(throws: AuthError.signedOut) { try await auth.accessToken() }

    #expect(stub.requests.count == 1)
    #expect(await store.loadRefreshToken() == nil)
    #expect(await auth.isSignedIn == false)
    await #expect(throws: AuthError.signedOut) { try await auth.accessToken() }
    #expect(stub.requests.count == 1)
  }

  @Test func otherTokenErrorsKeepTheRefreshToken() async throws {
    let stub = HTTPStub()
    stub.enqueue(.json(500, #"{"error":"backend_error"}"#))
    let (auth, store, _) = makeAuth(stub: stub)
    await #expect(throws: AuthError.tokenEndpoint(status: 500, error: "backend_error")) {
      try await auth.accessToken()
    }
    #expect(await store.loadRefreshToken() == "refresh-1")
  }

  @Test func signOutClearsEverything() async throws {
    let stub = HTTPStub()
    stub.enqueue(.json(200, tokenJSON(access: "at-1")))
    let (auth, store, _) = makeAuth(stub: stub)
    _ = try await auth.accessToken()
    try await auth.signOut()
    #expect(await store.loadRefreshToken() == nil)
    await #expect(throws: AuthError.signedOut) { try await auth.accessToken() }
  }
}

struct KeychainTokenStoreTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_KEYCHAIN"] == "1"))
  func roundTripsThroughRealKeychain() async throws {
    let store = KeychainTokenStore(service: "dev.krw.DriveMirror.tests", account: UUID().uuidString)
    try await store.saveRefreshToken("one")
    try await store.saveRefreshToken("two")
    #expect(try await store.loadRefreshToken() == "two")
    try await store.deleteRefreshToken()
    #expect(try await store.loadRefreshToken() == nil)
  }
}
