import Foundation

@testable import MirrorCore

/// Hands out `token-1`, then `token-2` after each invalidation.
actor StaticTokenProvider: AccessTokenProvider {
  private(set) var invalidations = 0

  func accessToken() -> String { "token-\(invalidations + 1)" }

  func invalidateAccessToken() { invalidations += 1 }
}
