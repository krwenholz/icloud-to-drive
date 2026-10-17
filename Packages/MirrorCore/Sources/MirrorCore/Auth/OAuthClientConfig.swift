import Foundation

/// The OAuth client ID and secret from the JSON Google offers when a Desktop app client is created.
public struct OAuthClientConfig: Sendable, Equatable, Decodable, CustomStringConvertible {
  public static let defaultAuthURI = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
  public static let defaultTokenURI = URL(string: "https://oauth2.googleapis.com/token")!

  public var clientID: String
  public var clientSecret: String
  public var authURI: URL
  public var tokenURI: URL

  public init(
    clientID: String, clientSecret: String,
    authURI: URL = defaultAuthURI, tokenURI: URL = defaultTokenURI
  ) {
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.authURI = authURI
    self.tokenURI = tokenURI
  }

  private struct Envelope: Decodable {
    struct Installed: Decodable {
      var clientId: String
      var clientSecret: String
      var authUri: URL?
      var tokenUri: URL?
    }
    var installed: Installed
  }

  public init(from decoder: any Decoder) throws {
    let installed = try Envelope(from: decoder).installed
    self.init(
      clientID: installed.clientId, clientSecret: installed.clientSecret,
      authURI: installed.authUri ?? Self.defaultAuthURI,
      tokenURI: installed.tokenUri ?? Self.defaultTokenURI)
  }

  /// Redacted so the secret can't leak through logs or test failure output.
  public var description: String {
    "OAuthClientConfig(clientID: \(clientID), clientSecret: <redacted>)"
  }
}

/// Locates, imports and loads `google-client.json` in Application Support.
public enum ClientFile {
  public static let fileName = "google-client.json"

  public static var defaultApplicationSupport: URL {
    URL.applicationSupportDirectory
  }

  public static func fileURL(applicationSupport: URL = defaultApplicationSupport) -> URL {
    applicationSupport
      .appending(path: AppIdentity.displayName, directoryHint: .isDirectory)
      .appending(path: fileName, directoryHint: .notDirectory)
  }

  public static func load(applicationSupport: URL = defaultApplicationSupport) throws
    -> OAuthClientConfig
  {
    let url = fileURL(applicationSupport: applicationSupport)
    guard let data = try? Data(contentsOf: url) else { throw AuthError.clientFileMissing(url) }
    return try decode(data)
  }

  /// Copies the chosen file into place after checking it parses, so a wrong pick never
  /// overwrites a working client file.
  @discardableResult
  public static func importFile(
    from source: URL, applicationSupport: URL = defaultApplicationSupport
  )
    throws -> OAuthClientConfig
  {
    let data: Data
    do { data = try Data(contentsOf: source) } catch {
      throw AuthError.clientFileInvalid("could not read \(source.lastPathComponent)")
    }
    let config = try decode(data)
    let destination = fileURL(applicationSupport: applicationSupport)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: destination, options: .atomic)
    // The file holds a client secret.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    return config
  }

  private static func decode(_ data: Data) throws -> OAuthClientConfig {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do { return try decoder.decode(OAuthClientConfig.self, from: data) } catch {
      throw AuthError.clientFileInvalid(
        "expected the JSON for a Desktop app OAuth client (with an \"installed\" section)")
    }
  }
}
