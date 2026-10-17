import Foundation
import Testing

@testable import MirrorCore

struct PKCEAndURLTests {
  @Test func verifierHasValidLengthAndCharset() {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    for _ in 0..<20 {
      let verifier = PKCE.generate().verifier
      #expect(verifier.count == 64)
      #expect(verifier.allSatisfy(allowed.contains))
    }
    #expect(PKCE.generate().verifier != PKCE.generate().verifier)
  }

  @Test func challengeMatchesRFC7636AppendixB() {
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test func randomStateIsURLSafeAndUnique() {
    let state = PKCE.randomState()
    #expect(!state.isEmpty)
    #expect(!state.contains { "+/=".contains($0) })
    #expect(state != PKCE.randomState())
  }

  @Test func authorizationURLCarriesEveryParameter() throws {
    let url = AuthorizationURL.make(
      config: testConfig, port: 51234, state: "st", codeChallenge: "chal")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "accounts.google.com")
    #expect(components.path == "/o/oauth2/v2/auth")
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(
      query == [
        "response_type": "code",
        "client_id": "client-id",
        "redirect_uri": "http://127.0.0.1:51234",
        "scope": "https://www.googleapis.com/auth/drive.file",
        "access_type": "offline",
        "prompt": "consent",
        "code_challenge": "chal",
        "code_challenge_method": "S256",
        "state": "st",
      ])
  }
}
