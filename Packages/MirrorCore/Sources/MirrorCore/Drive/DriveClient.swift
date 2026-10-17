import Foundation

/// A file or folder as Drive reports it, limited to the fields the engine uses.
public struct DriveFile: Equatable, Sendable {
  public static let docMimeType = "application/vnd.google-apps.document"
  public static let folderMimeType = "application/vnd.google-apps.folder"

  public var id: String
  public var name: String
  public var mimeType: String
  public var parents: [String]
  public var description: String?
  public var appProperties: [String: String]
  public var modifiedTime: Date?

  public init(
    id: String, name: String, mimeType: String, parents: [String] = [],
    description: String? = nil, appProperties: [String: String] = [:], modifiedTime: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.mimeType = mimeType
    self.parents = parents
    self.description = description
    self.appProperties = appProperties
    self.modifiedTime = modifiedTime
  }

  public var isFolder: Bool { mimeType == Self.folderMimeType }
}

/// Private `appProperties` keys the app writes. Drive caps each key plus value at 124 bytes,
/// which is why the full relative path lives in the description and only its hash lives here.
public enum AppPropertyKey {
  /// Root UUID.
  public static let root = "r"
  /// SHA-256 of the relative path (or directory path, for folders).
  public static let pathHash = "k"
  /// SHA-256 of the uploaded content.
  public static let contentHash = "h"
  /// What the app made this file for; see `DriveItemKind`.
  public static let kind = "t"
}

public enum DriveItemKind: String, Sendable {
  case mirrorFolder = "mirror"
  case rootFolder = "root"
  case folder = "dir"
  case doc = "doc"
  case statusDoc = "status"
}

/// How a changed file's Doc is refreshed.
public enum UpdateStrategy: String, Codable, CaseIterable, Sendable {
  /// Re-upload into the same Doc, keeping its file ID.
  case inPlace
  /// Create a new Doc and trash the old one, for when in-place conversion doesn't work.
  case replace
}

/// The Drive operations the sync engine needs, and nothing more.
public protocol DriveClient: Sendable {
  func createFolder(
    name: String, parentID: String?, description: String?, appProperties: [String: String]
  ) async throws -> DriveFile

  /// Uploads Markdown that Drive converts into a Google Doc.
  func createDoc(
    markdown: Data, name: String, parentID: String, description: String,
    appProperties: [String: String]
  ) async throws -> DriveFile

  /// Re-uploads Markdown into an existing Doc.
  func updateDoc(
    id: String, markdown: Data, description: String, appProperties: [String: String]
  ) async throws -> DriveFile

  /// Renames and/or moves a file. A `nil` name keeps the current one.
  func moveFile(id: String, name: String?, addParent: String?, removeParent: String?)
    async throws -> DriveFile

  /// Moves a file to the trash. The app never deletes permanently.
  func trashFile(id: String) async throws

  /// Every untrashed file with the given appProperty, across all pages.
  func listFiles(appProperty key: String, value: String) async throws -> [DriveFile]

  /// The signed-in user's email, or `nil` if the `drive.file` scope doesn't allow reading it.
  func userEmail() async throws -> String?
}

extension DriveClient {
  public func listFiles(root: UUID) async throws -> [DriveFile] {
    try await listFiles(appProperty: AppPropertyKey.root, value: root.uuidString)
  }
}

public enum DriveError: Error, Equatable, Sendable, CustomStringConvertible {
  /// Drive answered with an error status. `reason` is the first error's `reason` field.
  case http(status: Int, reason: String?, message: String?)
  case transport(code: Int, message: String)
  case invalidResponse(String)
  case notFound(id: String)

  public var description: String {
    switch self {
    case .http(let status, let reason, let message):
      "Drive returned \(status)\(reason.map { " (\($0))" } ?? ""): \(message ?? "no message")"
    case .transport(_, let message): "Network error: \(message)"
    case .invalidResponse(let detail): "Unexpected response from Drive: \(detail)"
    case .notFound(let id): "Drive file \(id) not found"
    }
  }
}
