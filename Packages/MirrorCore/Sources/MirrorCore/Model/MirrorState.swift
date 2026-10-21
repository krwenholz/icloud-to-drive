import Foundation

/// What the app last uploaded for one file.
public struct FileRecord: Codable, Equatable, Sendable {
  public var fileID: String
  public var contentHash: String
  /// Size and modification time at the last upload. `nil` after a rebuild from Drive, which
  /// forces one round of hashing (but no uploads) for unchanged files.
  public var size: Int64?
  public var modified: Date?

  public init(fileID: String, contentHash: String, size: Int64? = nil, modified: Date? = nil) {
    self.fileID = fileID
    self.contentHash = contentHash
    self.size = size
    self.modified = modified
  }
}

/// Everything the app knows about one root's mirror. It can always be rebuilt from Drive.
public struct RootState: Codable, Equatable, Sendable {
  /// The root's own folder under `iCloud Mirror`.
  public var folderID: String?
  /// Drive folder IDs for mirrored subdirectories, keyed by directory path relative to the root.
  public var folders: [String: String] = [:]
  public var files: [RelativePath: FileRecord] = [:]
  /// The last error per file, cleared when the file next syncs. Shown in the UI and status Doc.
  public var failures: [RelativePath: String] = [:]
  public var statusDocID: String?
  /// Docs replaced under `.replace` whose trash call failed. Retried on every reconcile so they
  /// don't linger as duplicates.
  public var orphanedFileIDs: [String] = []
  public var lastSuccessfulSync: Date?
  public var statusDocUpdatedAt: Date?

  public init() {}

  public init(from decoder: any Decoder) throws {
    // Tolerate missing keys so older state files keep loading as fields are added.
    let container = try decoder.container(keyedBy: CodingKeys.self)
    folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
    folders = try container.decodeIfPresent([String: String].self, forKey: .folders) ?? [:]
    files = try container.decodeIfPresent([RelativePath: FileRecord].self, forKey: .files) ?? [:]
    failures =
      try container.decodeIfPresent([RelativePath: String].self, forKey: .failures) ?? [:]
    statusDocID = try container.decodeIfPresent(String.self, forKey: .statusDocID)
    orphanedFileIDs =
      try container.decodeIfPresent([String].self, forKey: .orphanedFileIDs) ?? []
    lastSuccessfulSync = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulSync)
    statusDocUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .statusDocUpdatedAt)
  }

  /// The Drive folder that holds files in `directory`; the root folder for top-level files.
  public func folderID(forDirectory directory: String) -> String? {
    directory.isEmpty ? folderID : folders[directory]
  }
}

public struct MirrorState: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public var version = currentVersion
  /// The top-level `iCloud Mirror` folder.
  public var mirrorFolderID: String?
  /// The name the mirror folder was last given, so a changed setting renames the existing
  /// folder instead of creating a second one.
  public var mirrorFolderName: String?
  /// Keyed by root UUID string; JSON objects need string keys.
  public var roots: [String: RootState] = [:]

  public init() {}

  public init(from decoder: any Decoder) throws {
    // Tolerate missing keys so older state files keep loading as fields are added.
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
    mirrorFolderID = try container.decodeIfPresent(String.self, forKey: .mirrorFolderID)
    // Before the name was configurable, the folder was always created with the default name.
    mirrorFolderName =
      try container.decodeIfPresent(String.self, forKey: .mirrorFolderName)
      ?? (mirrorFolderID == nil ? nil : AppIdentity.driveRootFolderName)
    roots = try container.decodeIfPresent([String: RootState].self, forKey: .roots) ?? [:]
  }

  public subscript(root id: UUID) -> RootState {
    get { roots[id.uuidString] ?? RootState() }
    set { roots[id.uuidString] = newValue }
  }
}
