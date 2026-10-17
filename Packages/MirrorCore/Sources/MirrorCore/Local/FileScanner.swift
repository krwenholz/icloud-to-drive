import Foundation

/// Lists the mirrored files under a root.
///
/// Synchronous on purpose: callers run it off the main actor. Enumeration is a blocking walk.
public struct FileScanner: Sendable {
  public init() {}

  public func scan(root: URL, filter: PathFilter) -> ScanOutcome {
    let fileManager = FileManager.default
    // Resolve the root itself (it may be a symlink the user chose), but never anything inside it.
    let resolvedRoot = root.resolvingSymlinksInPath()

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory) else {
      return .unavailable(reason: "The folder no longer exists at \(root.path).")
    }
    guard isDirectory.boolValue else {
      return .unavailable(reason: "\(root.path) is not a folder.")
    }
    // An unreadable root must not look like an empty one, or every Doc would be trashed.
    do {
      _ = try fileManager.contentsOfDirectory(atPath: resolvedRoot.path)
    } catch {
      return .unavailable(reason: "The folder can't be read: \(error.localizedDescription)")
    }

    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
      .contentModificationDateKey,
    ]
    // A subfolder that can't be read would otherwise look empty, and every Doc in it would be
    // trashed. Treat any enumeration error as the root being unavailable instead.
    final class FirstError { var value: (URL, any Error)? }
    let firstError = FirstError()
    guard
      let enumerator = fileManager.enumerator(
        at: resolvedRoot,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { url, error in
          if firstError.value == nil { firstError.value = (url, error) }
          return true
        }
      )
    else {
      return .unavailable(reason: "The folder can't be enumerated: \(root.path)")
    }

    var files: [ScannedFile] = []
    while let url = enumerator.nextObject() as? URL {
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
      // The enumerator may report URLs under a different spelling of the root (`/private/var`
      // vs `/var`), so count components from the end using its depth instead of stripping a
      // prefix.
      let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")

      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        continue
      }
      if values.isDirectory == true {
        if !filter.mayDescend(into: relative) { enumerator.skipDescendants() }
        continue
      }
      guard values.isRegularFile == true, let path = try? RelativePath(relative),
        filter.includes(path)
      else { continue }
      files.append(
        ScannedFile(
          path: path,
          size: Int64(values.fileSize ?? 0),
          modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        ))
    }
    if let (url, error) = firstError.value {
      return .unavailable(
        reason: "Part of the folder can't be read (\(url.path)): \(error.localizedDescription)")
    }
    return .files(files.sorted { $0.path < $1.path })
  }
}
