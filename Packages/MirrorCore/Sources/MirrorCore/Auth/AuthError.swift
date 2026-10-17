import Foundation
import Security

/// Everything that can go wrong while signing in or obtaining an access token.
public enum AuthError: Error, Equatable, LocalizedError {
  /// No usable refresh token. The owner has to sign in again.
  case signedOut
  case accessDenied
  case authorizationFailed(String)
  case missingAuthorizationCode
  case stateMismatch
  case signInTimedOut
  case tokenEndpoint(status: Int, error: String?)
  case malformedTokenResponse
  case missingRefreshToken
  case clientFileMissing(URL)
  case clientFileInvalid(String)
  case keychain(OSStatus)
  case listenerFailed(String)

  public var errorDescription: String? {
    switch self {
    case .signedOut:
      return "Signed out of Google. Sign in again to resume mirroring."
    case .accessDenied:
      return "Google sign-in was cancelled or access was denied."
    case .authorizationFailed(let reason):
      return "Google sign-in failed: \(reason)."
    case .missingAuthorizationCode:
      return "Google's redirect did not include an authorization code."
    case .stateMismatch:
      return "Google sign-in response did not match this sign-in attempt. Try again."
    case .signInTimedOut:
      return "Google sign-in timed out. Try again."
    case .tokenEndpoint(let status, let error):
      return "Google's token endpoint returned HTTP \(status)\(error.map { " (\($0))" } ?? "")."
    case .malformedTokenResponse:
      return "Google's token response could not be read."
    case .missingRefreshToken:
      return "Google did not return a refresh token. Remove Drive Mirror from your Google "
        + "account's third-party access and sign in again."
    case .clientFileMissing(let url):
      return "Google client file not found at \(url.path). Import google-client.json first."
    case .clientFileInvalid(let reason):
      return "Google client file is not valid: \(reason)."
    case .keychain(let status):
      return "Keychain error \(status)."
    case .listenerFailed(let reason):
      return "Could not listen for Google's redirect: \(reason)."
    }
  }
}
