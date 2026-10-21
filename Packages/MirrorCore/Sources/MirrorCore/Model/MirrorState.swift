import Foundation

/// What the app last uploaded for one file.
public struct FileRecord: Codable, Equatable, Sendable {
  public var fileID: String
  public var contentHash: String
  /// Size and modification time at the last upload. `nil` after a rebuild from Drive, which
  /// forces one round of hashing (but no uploads) for unchanged files.
  public var size: Int64?
  public var modified: Date?
  /// Whether the Drive file is a converted Google Doc (`true`) or a plain Markdown file. When a
  /// root's setting stops matching, the file is re-created in the new format.
  public var converted: Bool

  public init(
    fileID: String, contentHash: String, size: Int64? = nil, modified: Date? = nil,
    converted: Bool = true
  ) {
    self.fileID = fileID
    self.contentHash = contentHash
    self.size = size
    self.modified = modified
    self.converted = converted
  }

  public init(from decoder: any Decoder) throws {
    // State from before plain files existed describes converted Docs.
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fileID = try container.decode(String.self, forKey: .fileID)
    contentHash = try container.decode(String.self, forKey: .contentHash)
    size = try container.decodeIfPresent(Int64.self, forKey: .size)
    modified = try container.decodeIfPresent(Date.self, forKey: .modified)
    converted = try container.decodeIfPresent(Bool.self, forKey: .converted) ?? true
  }
}

/// Why a file couldn't be mirrored, and since when.
public struct FailureRecord: Codable, Equatable, Sendable {
  /// A failure stops being shown, and the file stops being retried, after this long.
  public static let expiry: TimeInterval = 30 * 24 * 60 * 60

  public var message: String
  public var firstSeen: Date
  public var lastSeen: Date
  /// The file's size and modification time when it failed. A file that has changed since is
  /// a different problem and gets retried. `nil` for failures not tied to a file version,
  /// such as a trash that failed after the file was deleted locally.
  public var size: Int64?
  public var modified: Date?

  public init(
    message: String, firstSeen: Date, lastSeen: Date, size: Int64? = nil, modified: Date? = nil
  ) {
    self.message = message
    self.firstSeen = firstSeen
    self.lastSeen = lastSeen
    self.size = size
    self.modified = modified
  }

  /// Old enough to be hidden. Whether the file has also changed is up to the caller, which has
  /// the scan; a changed file is retried and then recorded afresh, so this stays accurate.
  public func isExpired(at now: Date) -> Bool {
    size != nil && now.timeIntervalSince(firstSeen) > Self.expiry
  }

  func isUnchanged(since file: ScannedFile) -> Bool {
    size == file.size && modified == file.modified
  }

  /// The record after a failure: the same problem keeps its `firstSeen`, a changed file starts
  /// a new clock.
  func recurring(message: String, file: ScannedFile?, at now: Date) -> FailureRecord {
    guard size == file?.size, modified == file?.modified else {
      return FailureRecord(
        message: message, firstSeen: now, lastSeen: now, size: file?.size, modified: file?.modified)
    }
    return FailureRecord(
      message: message, firstSeen: firstSeen, lastSeen: now, size: size, modified: modified)
  }
}

/// Everything the app knows about one root's mirror. It can always be rebuilt from Drive.
public struct RootState: Codable, Equatable, Sendable {
  /// The root's own folder under `iCloud Mirror`.
  public var folderID: String?
  /// The name `folderID` was last given. `nil` (state from before this was tracked, or just
  /// rebuilt without a name) means the next reconcile renames it to be safe.
  public var folderName: String?
  /// Drive folder IDs for mirrored subdirectories, keyed by directory path relative to the root.
  public var folders: [String: String] = [:]
  public var files: [RelativePath: FileRecord] = [:]
  /// The last error per file, cleared when the file next syncs. Shown in the UI and status Doc
  /// until it is older than `FailureRecord.expiry`.
  public var failures: [RelativePath: FailureRecord] = [:]
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
    folderName = try container.decodeIfPresent(String.self, forKey: .folderName)
    folders = try container.decodeIfPresent([String: String].self, forKey: .folders) ?? [:]
    files = try container.decodeIfPresent([RelativePath: FileRecord].self, forKey: .files) ?? [:]
    // Failures used to be bare strings. They are only advisory and the next reconcile finds
    // them again, so drop them rather than fail to load the whole state.
    failures =
      (try? container.decodeIfPresent([RelativePath: FailureRecord].self, forKey: .failures))
      ?? [:]
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
