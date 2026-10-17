import Foundation

/// Everything the CLI touches outside its own logic, so tests can swap it.
public struct CLIEnvironment: Sendable {
  public var paths: AppPaths
  public var out: @Sendable (String) -> Void
  public var err: @Sendable (String) -> Void
  /// A signed-in Drive client; throws if the owner hasn't signed in.
  public var makeDrive: @Sendable () async throws -> any ProbeDriveClient
  /// Runs the sign-in flow and returns the account's email, if readable.
  public var signIn: @Sendable () async throws -> String?
  public var reader: any FileReading
  public var now: @Sendable () -> Date

  public init(
    paths: AppPaths,
    out: @escaping @Sendable (String) -> Void,
    err: @escaping @Sendable (String) -> Void,
    makeDrive: @escaping @Sendable () async throws -> any ProbeDriveClient,
    signIn: @escaping @Sendable () async throws -> String?,
    reader: any FileReading = CoordinatedFileReader(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.paths = paths
    self.out = out
    self.err = err
    self.makeDrive = makeDrive
    self.signIn = signIn
    self.reader = reader
    self.now = now
  }

  /// The real thing: stdout/stderr, the shared Keychain item, and Google's servers.
  public static func live(paths: AppPaths = AppPaths()) -> CLIEnvironment {
    CLIEnvironment(
      paths: paths,
      out: { print($0) },
      err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
      makeDrive: {
        let auth = try liveAuth(paths: paths)
        return GoogleDriveClient(tokens: auth)
      },
      signIn: {
        let auth = try liveAuth(paths: paths)
        try await auth.signIn { url in
          print("Opening your browser. If nothing opens, visit:\n\(url.absoluteString)")
          openInBrowser(url)
        }
        return try? await GoogleDriveClient(tokens: auth).userEmail()
      })
  }

  private static func liveAuth(paths: AppPaths) throws -> GoogleAuth {
    let config = try ClientFile.load(applicationSupport: paths.applicationSupport)
    // The default Keychain service is shared with the app, so one sign-in serves both.
    return GoogleAuth(config: config, store: KeychainTokenStore())
  }

  private static func openInBrowser(_ url: URL) {
    // `open` avoids linking AppKit into a command-line tool.
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try? process.run()
  }
}
