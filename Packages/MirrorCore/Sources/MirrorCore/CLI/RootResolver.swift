import CryptoKit
import Foundation

/// A root the CLI will act on, and where its state lives.
public struct ResolvedRoot: Equatable, Sendable {
  public var root: RootConfig
  /// `true` when the folder isn't in the app's config.
  public var isTemporary: Bool
  public var stateFile: URL
}

public enum RootResolver {
  public static let temporaryStateFileName = "mirrorctl-state.json"

  /// Symlinks resolved so `/tmp/x` and `/private/tmp/x` name the same root.
  public static func canonicalPath(_ path: String) -> String {
    URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// Derived from the path so reruns find the Docs an earlier run made instead of duplicating
  /// them. SHA-256 is truncated to a UUID; the version nibble says "name-based" (5).
  public static func temporaryID(forCanonicalPath path: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data("mirrorctl:\(path)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  public static func resolve(path: String, config: MirrorConfig, paths: AppPaths) -> ResolvedRoot {
    let canonical = canonicalPath(path)
    if let match = config.roots.first(where: { canonicalPath($0.path) == canonical }) {
      return ResolvedRoot(root: match, isTemporary: false, stateFile: paths.stateFile)
    }
    let name = URL(filePath: canonical).lastPathComponent
    let root = RootConfig(
      id: temporaryID(forCanonicalPath: canonical), displayName: name.isEmpty ? "Folder" : name,
      path: canonical)
    return ResolvedRoot(
      root: root, isTemporary: true,
      // Separate from the app's state so experiments can't confuse it.
      stateFile: paths.directory.appending(path: temporaryStateFileName))
  }
}
