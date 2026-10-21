import Foundation

/// A Drive client that can also read back what it wrote, which the probe needs and the engine
/// doesn't.
public protocol ProbeDriveClient: DriveClient {
  func exportMarkdown(id: String) async throws -> String
}

extension GoogleDriveClient: ProbeDriveClient {}

extension InMemoryDriveClient: ProbeDriveClient {
  /// Returns the uploaded text unchanged; the fake does no conversion.
  public func exportMarkdown(id: String) async throws -> String {
    guard let item = item(id), !item.trashed else { throw DriveError.notFound(id: id) }
    return String(decoding: item.content ?? Data(), as: UTF8.self)
  }
}
