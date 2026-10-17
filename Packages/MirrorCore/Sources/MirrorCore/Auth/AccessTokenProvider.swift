/// Supplies OAuth access tokens to the Drive client.
public protocol AccessTokenProvider: Sendable {
  /// A token valid for at least the next request, refreshing first if it's about to expire.
  func accessToken() async throws -> String
  /// Drops the cached token after a 401 so the next `accessToken()` refreshes.
  func invalidateAccessToken() async
}
