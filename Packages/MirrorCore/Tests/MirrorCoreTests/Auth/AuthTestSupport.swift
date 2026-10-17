import Foundation

@testable import MirrorCore

/// Mutable clock for expiry tests.
final class TestClock: @unchecked Sendable {
  // @unchecked: `date` is only touched under `lock`.
  private let lock = NSLock()
  private var date = Date(timeIntervalSince1970: 1_000_000)

  var now: Date { lock.withLock { date } }
  func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

let testConfig = OAuthClientConfig(clientID: "client-id", clientSecret: "client-secret")

func tokenJSON(access: String, expiresIn: Int = 3600, refresh: String? = nil) -> String {
  let refreshPart = refresh.map { #","refresh_token":"\#($0)""# } ?? ""
  return
    #"{"access_token":"\#(access)","expires_in":\#(expiresIn),"token_type":"Bearer"\#(refreshPart)}"#
}

func formFields(_ body: Data) -> [String: String] {
  var components = URLComponents()
  components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
  return Dictionary(
    (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}
