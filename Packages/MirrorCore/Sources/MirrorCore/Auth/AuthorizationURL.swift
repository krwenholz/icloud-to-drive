import Foundation

enum AuthorizationURL {
  static let scope = "https://www.googleapis.com/auth/drive.file"

  static func redirectURI(port: Int) -> String { "http://127.0.0.1:\(port)" }

  static func make(config: OAuthClientConfig, port: Int, state: String, codeChallenge: String)
    -> URL
  {
    var components = URLComponents(url: config.authURI, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: config.clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI(port: port)),
      URLQueryItem(name: "scope", value: scope),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
    ]
    return components.url!
  }
}
