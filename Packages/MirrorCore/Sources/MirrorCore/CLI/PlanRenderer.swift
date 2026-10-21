import Foundation

/// Turns a `SyncPlan` into the lines `sync --dry-run` prints.
public enum PlanRenderer {
  public static func render(_ plan: SyncPlan, scannedCount: Int) -> [String] {
    var lines: [String] = []
    var counts = (create: 0, update: 0, move: 0, trash: 0, folder: 0)
    for operation in plan.operations {
      switch operation {
      case .createFolder(let directory):
        counts.folder += 1
        lines.append("folder  \(directory)/")
      case .createDoc(let file, _):
        counts.create += 1
        lines.append("create  \(file.path)")
      case .updateDoc(let file, _, _), .reformatDoc(let file, _, _):
        counts.update += 1
        lines.append("update  \(file.path)")
      case .moveDoc(let from, let to, _):
        counts.move += 1
        lines.append("move    \(from) -> \(to.path)")
      case .trashDoc(let path, _):
        counts.trash += 1
        lines.append("trash   \(path)")
      case .recordUnchanged:
        break
      }
    }
    for case .trashDoc(let path, _) in plan.heldDeletions { lines.append("held    \(path)") }
    for path in plan.deferred { lines.append("defer   \(path)") }

    let unchanged = max(
      0,
      scannedCount - counts.create - counts.update - counts.move
        - plan.deferred.count)
    if lines.isEmpty { lines.append("Nothing to do.") }
    lines.append("")
    lines.append(
      "Summary: \(counts.create) create, \(counts.update) update, \(counts.move) move, "
        + "\(counts.trash) trash, \(counts.folder) folders, \(unchanged) unchanged")
    if !plan.deferred.isEmpty {
      lines.append("\(plan.deferred.count) deferred (still downloading from iCloud or unread)")
    }
    switch plan.attention {
    case .massDeletion(let pending, let mirrored)?:
      lines.append(
        "Mass deletion held: \(pending) of \(mirrored) mirrored files would be trashed. "
          + "The app asks before applying these.")
    case .rootUnavailable(let reason)?:
      lines.append("Root unavailable: \(reason)")
    case nil:
      break
    }
    return lines
  }
}
