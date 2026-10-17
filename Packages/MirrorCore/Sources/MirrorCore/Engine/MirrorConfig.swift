import Foundation

/// One local folder the owner chose to mirror.
public struct RootConfig: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var displayName: String
  public var path: String
  /// A regular bookmark, so the folder can be found again after a rename.
  public var bookmark: Data?
  public var filter: PathFilter

  public init(
    id: UUID = UUID(), displayName: String, path: String, bookmark: Data? = nil,
    filter: PathFilter = PathFilter()
  ) {
    self.id = id
    self.displayName = displayName
    self.path = path
    self.bookmark = bookmark
    self.filter = filter
  }

  public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

public struct MirrorConfig: Codable, Equatable, Sendable {
  public var roots: [RootConfig] = []
  public var updateStrategy: UpdateStrategy = .inPlace
  public var isPaused = false

  public init(roots: [RootConfig] = [], updateStrategy: UpdateStrategy = .inPlace) {
    self.roots = roots
    self.updateStrategy = updateStrategy
  }

  public init(from decoder: any Decoder) throws {
    // Tolerate missing keys so older config files keep loading as fields are added.
    let container = try decoder.container(keyedBy: CodingKeys.self)
    roots = try container.decodeIfPresent([RootConfig].self, forKey: .roots) ?? []
    updateStrategy =
      try container.decodeIfPresent(UpdateStrategy.self, forKey: .updateStrategy) ?? .inPlace
    isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
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
