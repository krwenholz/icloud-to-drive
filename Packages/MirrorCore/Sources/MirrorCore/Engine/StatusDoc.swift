import Foundation

/// The `_sync-status` Doc in each root's Drive folder, which tells a reader (often Claude) how
/// fresh the mirror is.
public enum StatusDoc {
  public static let name = "_sync-status"
  /// Refresh at least this often even when nothing changed.
  public static let maxAge: TimeInterval = 60 * 60
  static let maxListedFailures = 20

  public struct Content: Equatable, Sendable {
    public var rootName: String
    public var lastSuccessfulSync: Date
    public var mirroredFiles: Int
    public var failures: [RelativePath: String]
    public var heldDeletions: Int
    public var waitingForDownload: Int
  }

  public static func markdown(_ content: Content, timeZone: TimeZone, locale: Locale) -> String {
    let local = DateFormatter()
    local.dateStyle = .full
    local.timeStyle = .long
    local.timeZone = timeZone
    local.locale = locale
    let iso = ISO8601DateFormatter()

    var lines = [
      "# Drive Mirror sync status: \(content.rootName)",
      "",
      "This Doc is maintained by Drive Mirror, which mirrors Markdown notes from the owner's "
        + "iCloud Drive into this folder. The notes on iCloud are the source of truth.",
      "",
      "- Last successful sync: \(local.string(from: content.lastSuccessfulSync)) "
        + "(\(iso.string(from: content.lastSuccessfulSync)))",
      "- Mirrored files: \(content.mirroredFiles)",
    ]
    if content.failures.isEmpty {
      lines.append("- Failing files: none")
    } else {
      lines.append("- Failing files: \(content.failures.count)")
      for (path, message) in content.failures.sorted(by: { $0.key < $1.key })
        .prefix(maxListedFailures)
      {
        lines.append("    - `\(path.value)`: \(message)")
      }
      if content.failures.count > maxListedFailures {
        lines.append("    - and \(content.failures.count - maxListedFailures) more")
      }
    }
    if content.waitingForDownload > 0 {
      lines.append("- Waiting for iCloud to download: \(content.waitingForDownload)")
    }
    if content.heldDeletions > 0 {
      lines.append(
        "- Deletions on hold: \(content.heldDeletions) Docs would be trashed, which looks like "
          + "a mistake, so they are kept until the owner confirms.")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
