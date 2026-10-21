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
    public var failures: [RelativePath: FailureRecord]
    /// How many deletions are on hold, which can be more than `heldDeletionPaths` lists.
    public var heldDeletions: Int
    public var heldDeletionPaths: [RelativePath]
    public var waitingForDownload: Int
    public var changes: RootSyncReport.ChangeCounts
    public var duration: TimeInterval
    public var machineName: String?
    public var updateStrategy: UpdateStrategy
    public var convertsToDocs: Bool
  }

  public static func markdown(_ content: Content, timeZone: TimeZone, locale: Locale) -> String {
    let local = DateFormatter()
    local.dateStyle = .full
    local.timeStyle = .long
    local.timeZone = timeZone
    local.locale = locale
    let day = DateFormatter()
    day.dateStyle = .medium
    day.timeStyle = .none
    day.timeZone = timeZone
    day.locale = locale
    let iso = ISO8601DateFormatter()
    let changes = content.changes

    var lines = [
      "# Drive Mirror sync status: \(content.rootName)",
      "",
      "This Doc is maintained by Drive Mirror, which mirrors Markdown notes from the owner's "
        + "iCloud Drive into this folder. The notes on iCloud are the source of truth.",
      "",
      "- Last successful sync: \(local.string(from: content.lastSuccessfulSync)) "
        + "(\(iso.string(from: content.lastSuccessfulSync)))",
      "- Last sync took: \(durationText(content.duration))"
        + (content.machineName.map { ", on \($0)" } ?? ""),
      "- Changed in the last sync: \(changes.created) created, \(changes.updated) updated, "
        + "\(changes.moved) moved, \(changes.trashed) trashed",
      "- Mirrored files: \(content.mirroredFiles)",
      "- Files are stored as: "
        + (content.convertsToDocs
          ? "Google Docs, converted from Markdown" : "plain Markdown files, not converted"),
      "- Update strategy: "
        + (content.updateStrategy == .inPlace
          ? "in place (edits keep the same file, so links to it keep working)"
          : "replace (each edit makes a new copy and trashes the old one, so links to it change)"),
    ]
    if content.failures.isEmpty {
      lines.append("- Failing files: none")
    } else {
      lines.append("- Failing files: \(content.failures.count)")
      for (path, failure) in content.failures.sorted(by: { $0.key < $1.key })
        .prefix(maxListedFailures)
      {
        lines.append(
          "    - `\(path.value)`: \(failure.message) (since \(day.string(from: failure.firstSeen)))"
        )
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
        "- Deletions on hold: \(content.heldDeletions) mirrored files would be trashed, which "
          + "looks like a mistake, so they are kept until the owner confirms.")
      for path in content.heldDeletionPaths.prefix(RootSyncReport.maxHeldPaths) {
        lines.append("    - `\(path.value)`")
      }
      let unlisted =
        content.heldDeletions - min(content.heldDeletionPaths.count, RootSyncReport.maxHeldPaths)
      if unlisted > 0 { lines.append("    - and \(unlisted) more") }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func durationText(_ seconds: TimeInterval) -> String {
    if seconds < 1 { return "under a second" }
    let whole = Int(seconds.rounded())
    return "\(whole) second\(whole == 1 ? "" : "s")"
  }
}
