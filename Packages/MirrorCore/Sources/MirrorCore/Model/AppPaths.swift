import Foundation

/// Where the app and `mirrorctl` keep their files. Both use the same directory, so signing in or
/// syncing with one is visible to the other.
public struct AppPaths: Sendable {
  /// `~/Library/Application Support`, or a temp directory in tests.
  public var applicationSupport: URL

  public init(applicationSupport: URL = URL.applicationSupportDirectory) {
    self.applicationSupport = applicationSupport
  }

  public var directory: URL {
    applicationSupport.appending(path: AppIdentity.displayName, directoryHint: .isDirectory)
  }

  public var configFile: URL { directory.appending(path: "config.json") }
  public var stateFile: URL { directory.appending(path: "state.json") }
  public var logFile: URL { directory.appending(path: "drive-mirror.log") }
  public var clientFile: URL { ClientFile.fileURL(applicationSupport: applicationSupport) }
}
