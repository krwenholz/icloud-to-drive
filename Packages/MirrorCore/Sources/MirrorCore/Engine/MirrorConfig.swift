import Foundation

/// One local folder the owner chose to mirror.
public struct RootConfig: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var displayName: String
  public var path: String
  /// A regular bookmark, so the folder can be found again after a rename.
  public var bookmark: Data?
  public var filter: PathFilter
  /// Upload as Google Docs (the default) or as plain Markdown files. Claude's Drive connector
  /// reads Docs best, but some owners prefer to keep the `.md` files as they are.
  public var convertToDocs: Bool

  public init(
    id: UUID = UUID(), displayName: String, path: String, bookmark: Data? = nil,
    filter: PathFilter = PathFilter(), convertToDocs: Bool = true
  ) {
    self.id = id
    self.displayName = displayName
    self.path = path
    self.bookmark = bookmark
    self.filter = filter
    self.convertToDocs = convertToDocs
  }

  public init(from decoder: any Decoder) throws {
    // Tolerate missing keys so older config files keep loading as fields are added.
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    displayName = try container.decode(String.self, forKey: .displayName)
    path = try container.decode(String.self, forKey: .path)
    bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
    filter = try container.decodeIfPresent(PathFilter.self, forKey: .filter) ?? PathFilter()
    convertToDocs = try container.decodeIfPresent(Bool.self, forKey: .convertToDocs) ?? true
  }

  public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

/// How often every root is reconciled in full, as a safety net behind the file watcher.
public enum FullSyncInterval: String, Codable, CaseIterable, Sendable {
  case fifteenMinutes
  case oneHour
  case sixHours

  public static let `default` = FullSyncInterval.oneHour

  public var duration: Duration {
    switch self {
    case .fifteenMinutes: .seconds(15 * 60)
    case .oneHour: .seconds(60 * 60)
    case .sixHours: .seconds(6 * 60 * 60)
    }
  }

  public var title: String {
    switch self {
    case .fifteenMinutes: "15 minutes"
    case .oneHour: "1 hour"
    case .sixHours: "6 hours"
    }
  }
}

public struct MirrorConfig: Codable, Equatable, Sendable {
  public var roots: [RootConfig] = []
  public var updateStrategy: UpdateStrategy = .inPlace
  public var isPaused = false
  /// The name of the top-level Drive folder that holds every root's mirror.
  public var driveFolderName = AppIdentity.driveRootFolderName
  public var fullSyncInterval = FullSyncInterval.default

  public init(
    roots: [RootConfig] = [], updateStrategy: UpdateStrategy = .inPlace,
    driveFolderName: String = AppIdentity.driveRootFolderName,
    fullSyncInterval: FullSyncInterval = .default
  ) {
    self.roots = roots
    self.fullSyncInterval = fullSyncInterval
    self.updateStrategy = updateStrategy
    self.driveFolderName = Self.normalizedDriveFolderName(driveFolderName)
  }

  /// Blank names fall back to the default, so the owner can clear the field to reset it.
  public static func normalizedDriveFolderName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? AppIdentity.driveRootFolderName : trimmed
  }

  public init(from decoder: any Decoder) throws {
    // Tolerate missing keys so older config files keep loading as fields are added.
    let container = try decoder.container(keyedBy: CodingKeys.self)
    roots = try container.decodeIfPresent([RootConfig].self, forKey: .roots) ?? []
    updateStrategy =
      try container.decodeIfPresent(UpdateStrategy.self, forKey: .updateStrategy) ?? .inPlace
    isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
    // An interval from a newer or hand-edited file that we don't know falls back to the default.
    fullSyncInterval =
      (try? container.decodeIfPresent(FullSyncInterval.self, forKey: .fullSyncInterval))
      ?? .default
    driveFolderName = Self.normalizedDriveFolderName(
      try container.decodeIfPresent(String.self, forKey: .driveFolderName) ?? "")
  }
}

/// Reads and writes a Codable value as a JSON file, replacing it atomically.
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
  public enum LoadResult: Sendable {
    case loaded(Value)
    case missing
    case corrupt(String)
  }

  public let url: URL

  public init(url: URL) { self.url = url }

  public func load() -> LoadResult {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return .missing
    } catch {
      return .corrupt("can't read \(url.lastPathComponent): \(error.localizedDescription)")
    }
    do {
      return .loaded(try JSONDecoder().decode(Value.self, from: data))
    } catch {
      return .corrupt("can't decode \(url.lastPathComponent): \(error)")
    }
  }

  public func save(_ value: Value) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  public func remove() throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}
