/// Formats a reconcile report for the terminal.
public enum ReportRenderer {
  public static func render(_ report: RootSyncReport, rootName: String) -> [String] {
    var lines: [String] = []
    if let error = report.error {
      lines.append("Sync of '\(rootName)' stopped: \(error)")
    } else {
      lines.append(
        "Synced '\(rootName)': \(report.applied) applied, \(report.failures.count) failed, "
          + "\(report.deferred.count) deferred, \(report.heldDeletions) held deletions")
    }
    for (path, message) in report.failures.sorted(by: { $0.key < $1.key }) {
      lines.append("failed  \(path): \(message)")
    }
    for path in report.deferred { lines.append("defer   \(path)") }
    switch report.attention {
    case .massDeletion(let pending, let mirrored)?:
      lines.append(
        "Mass deletion held: \(pending) of \(mirrored) mirrored files would be trashed.")
    case .rootUnavailable(let reason)?:
      lines.append("Root unavailable: \(reason)")
    case nil:
      break
    }
    return lines
  }

  /// A reconcile is clean when it finished and no file failed.
  public static func isSuccess(_ report: RootSyncReport) -> Bool {
    report.completed && report.failures.isEmpty
  }
}
