import Foundation
import Testing

@testable import MirrorCore

struct RedirectServerTests {
  typealias Callback = LoopbackRedirectServer.Callback

  @Test func evaluateAcceptsMatchingState() {
    let result = LoopbackRedirectServer.evaluate(
      Callback(code: "abc", state: "s1"), expectedState: "s1")
    #expect(result == .success("abc"))
  }

  @Test func evaluateRejectsStateMismatch() {
    let result = LoopbackRedirectServer.evaluate(
      Callback(code: "abc", state: "evil"), expectedState: "s1")
    #expect(result == .failure(.stateMismatch))
    let missing = LoopbackRedirectServer.evaluate(Callback(code: "abc"), expectedState: "s1")
    #expect(missing == .failure(.stateMismatch))
  }

  @Test func evaluateReportsAccessDenied() {
    let result = LoopbackRedirectServer.evaluate(
      Callback(state: "s1", error: "access_denied"), expectedState: "s1")
    #expect(result == .failure(.accessDenied))
    let other = LoopbackRedirectServer.evaluate(
      Callback(state: "s1", error: "server_error"), expectedState: "s1")
    #expect(other == .failure(.authorizationFailed("server_error")))
  }

  @Test func parseIgnoresStrayRequests() {
    #expect(
      LoopbackRedirectServer.parseCallback(requestHead: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
    #expect(LoopbackRedirectServer.parseCallback(requestHead: "GET / HTTP/1.1\r\n\r\n") == nil)
    #expect(
      LoopbackRedirectServer.parseCallback(requestHead: "POST /?code=a HTTP/1.1\r\n\r\n") == nil)
    #expect(LoopbackRedirectServer.parseCallback(requestHead: "garbage") == nil)
    #expect(
      LoopbackRedirectServer.parseCallback(requestHead: "GET /?code=a%20b&state=s HTTP/1.1\r\n\r\n")
        == Callback(code: "a b", state: "s"))
  }

  @Test func realListenerReceivesCodeAndServesPage() async throws {
    let server = try LoopbackRedirectServer()
    let port = try await server.start()
    let waiting = Task { try await server.waitForCode(expectedState: "xyz") }

    // A stray request first: must not end the wait or crash.
    let stray = try await URLSession.shared.data(
      from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
    #expect((stray.1 as? HTTPURLResponse)?.statusCode == 404)

    let url = URL(string: "http://127.0.0.1:\(port)/?code=abc&state=xyz")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let code = try await waiting.value
    await server.stop()

    #expect(code == "abc")
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("You can close this tab"))
  }
}
