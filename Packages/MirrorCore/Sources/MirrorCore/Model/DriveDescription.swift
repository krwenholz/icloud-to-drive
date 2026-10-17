import Foundation

/// The human-readable descriptions written on Drive items, and recovering paths from them.
///
/// A description reads `<root name> / <relative path>`. Recovery doesn't trust the root name
/// (the owner may have renamed the root since); it tries every ` / ` split and keeps the one
/// whose hash matches the item's `k` property.
public enum DriveDescription {
  public static func doc(rootName: String, path: RelativePath) -> String {
    path.docDescription(rootName: rootName)
  }

  public static func folder(rootName: String, directory: String) -> String {
    "\(rootName) / \(directory)/"
  }

  public static func rootFolder(rootName: String) -> String { "\(rootName) /" }

  public static func recoverPath(from description: String?, pathHash: String?) -> RelativePath? {
    candidates(description).lazy.compactMap { try? RelativePath($0) }
      .first { $0.pathHash == pathHash }
  }

  public static func recoverDirectory(from description: String?, pathHash: String?) -> String? {
    candidates(description).lazy
      .filter { $0.hasSuffix("/") }
      .map { String($0.dropLast()) }
      .first { !$0.isEmpty && Hashing.sha256Hex($0) == pathHash }
  }

  private static func candidates(_ description: String?) -> [String] {
    guard let description else { return [] }
    var result: [String] = []
    var searchStart = description.startIndex
    while let range = description.range(of: " / ", range: searchStart..<description.endIndex) {
      result.append(String(description[range.upperBound...]))
      searchStart = description.index(after: range.lowerBound)
    }
    return result
  }
}
