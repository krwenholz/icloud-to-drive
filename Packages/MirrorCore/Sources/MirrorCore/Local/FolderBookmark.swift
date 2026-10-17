import Foundation

/// Regular (not security-scoped; the app isn't sandboxed) bookmarks, kept next to a root's path
/// so the folder can be found again after a rename or move.
public enum FolderBookmark {
  public struct ResolutionError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
  }

  public static func create(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  /// `isStale` means the folder moved; the caller should store a fresh bookmark and path.
  public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil,
        bookmarkDataIsStale: &isStale)
      return (url, isStale)
    } catch {
      throw ResolutionError(
        message: "The folder can't be found any more: \(error.localizedDescription)")
    }
  }
}
