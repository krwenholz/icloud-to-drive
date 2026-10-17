import Foundation
import Security

/// Persists the long-lived refresh token. Access tokens never go through here.
public protocol TokenStore: Sendable {
  func loadRefreshToken() async throws -> String?
  func saveRefreshToken(_ token: String) async throws
  func deleteRefreshToken() async throws
}

public actor InMemoryTokenStore: TokenStore {
  private var token: String?

  public init(token: String? = nil) {
    self.token = token
  }

  public func loadRefreshToken() -> String? { token }
  public func saveRefreshToken(_ token: String) { self.token = token }
  public func deleteRefreshToken() { token = nil }
}

/// Keychain-backed store. The service defaults to the bundle identifier so the app and
/// `mirrorctl` share one sign-in.
public struct KeychainTokenStore: TokenStore {
  public let service: String
  public let account: String

  public init(
    service: String = AppIdentity.bundleIdentifier, account: String = "google-refresh-token"
  ) {
    self.service = service
    self.account = account
  }

  private var identity: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  public func loadRefreshToken() async throws -> String? {
    var query = identity
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw AuthError.keychain(status)
    }
    return String(data: data, encoding: .utf8)
  }

  public func saveRefreshToken(_ token: String) async throws {
    let data = Data(token.utf8)
    let update = SecItemUpdate(
      identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw AuthError.keychain(update) }
    var item = identity
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw AuthError.keychain(status) }
  }

  public func deleteRefreshToken() async throws {
    let status = SecItemDelete(identity as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AuthError.keychain(status)
    }
  }
}
