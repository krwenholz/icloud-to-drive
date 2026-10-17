import CryptoKit
import Foundation
import Security

/// PKCE (RFC 7636) verifier and S256 challenge pair.
struct PKCE: Equatable {
  let verifier: String

  private static let alphabet = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)

  init(verifier: String) {
    self.verifier = verifier
  }

  static func generate(length: Int = 64) -> PKCE {
    var chars: [UInt8] = []
    while chars.count < length {
      // Rejecting bytes >= 198 (3 * 66) avoids modulo bias.
      for byte in randomBytes(count: length) where byte < 198 && chars.count < length {
        chars.append(alphabet[Int(byte) % alphabet.count])
      }
    }
    return PKCE(verifier: String(decoding: chars, as: UTF8.self))
  }

  var challenge: String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
  }

  /// URL-safe random string for the OAuth `state` parameter.
  static func randomState() -> String {
    Data(randomBytes(count: 32)).base64URLEncoded
  }

  private static func randomBytes(count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    // A failing system RNG means nothing about this process can be trusted.
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return bytes
  }
}

extension Data {
  var base64URLEncoded: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
