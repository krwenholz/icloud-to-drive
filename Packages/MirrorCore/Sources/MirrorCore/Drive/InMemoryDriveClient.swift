import Foundation

/// A Drive that lives in memory, for engine tests and previews. It enforces the rules the real
/// API does that the engine relies on (parents must exist, trashed files drop out of listings)
/// and can fail chosen calls on demand.
public actor InMemoryDriveClient: DriveClient {
  public struct Item: Equatable, Sendable {
    public var file: DriveFile
    public var content: Data?
    public var trashed = false
  }

  public enum Call: Equatable, Sendable {
    case createFolder(name: String)
    case createFile(name: String)
    case updateFile(id: String)
    case moveFile(id: String)
    case trashFile(id: String)
    case listFiles
    case userEmail
  }

  private struct Failure {
    var matches: @Sendable (Call) -> Bool
    var error: DriveError
    var remaining: Int
  }

  public private(set) var items: [String: Item] = [:]
  public private(set) var calls: [Call] = []
  public var email: String? = "owner@example.com"
  private var failures: [Failure] = []
  private var nextID = 1
  private var tick: TimeInterval = 0

  public init() {}

  /// Makes the next `count` calls matching `predicate` throw `error` instead of running.
  public func failNext(
    _ count: Int = 1,
    with error: DriveError = .http(status: 500, reason: "backendError", message: "injected"),
    where predicate: @escaping @Sendable (Call) -> Bool
  ) {
    failures.append(Failure(matches: predicate, error: error, remaining: count))
  }

  public func item(_ id: String) -> Item? { items[id] }

  public func setEmail(_ email: String?) { self.email = email }

  /// Untrashed items under `folderID`, keyed by their path of names, e.g. `projects/garden`.
  public func tree(under folderID: String) -> [String: Item] {
    var result: [String: Item] = [:]
    func walk(_ parent: String, _ prefix: String) {
      for item in items.values where !item.trashed && item.file.parents.contains(parent) {
        let path = prefix.isEmpty ? item.file.name : "\(prefix)/\(item.file.name)"
        result[path] = item
        if item.file.isFolder { walk(item.file.id, path) }
      }
    }
    walk(folderID, "")
    return result
  }

  /// `tree(under:)` rendered as sorted paths, with a trailing `/` on folders.
  public func treeListing(under folderID: String) -> [String] {
    tree(under: folderID).map { $0.value.file.isFolder ? "\($0.key)/" : $0.key }.sorted()
  }

  // MARK: - DriveClient

  public func createFolder(
    name: String, parentID: String?, description: String?, appProperties: [String: String]
  ) throws -> DriveFile {
    try record(.createFolder(name: name))
    if let parentID { try requireFolder(parentID) }
    return insert(
      DriveFile(
        id: "", name: name, mimeType: DriveFile.folderMimeType,
        parents: parentID.map { [$0] } ?? ["my-drive"], description: description,
        appProperties: appProperties),
      content: nil)
  }

  public func createFile(
    markdown: Data, name: String, parentID: String, description: String,
    appProperties: [String: String], convert: Bool
  ) throws -> DriveFile {
    try record(.createFile(name: name))
    try requireFolder(parentID)
    return insert(
      DriveFile(
        id: "", name: name, mimeType: convert ? DriveFile.docMimeType : DriveFile.markdownMimeType,
        parents: [parentID],
        description: description, appProperties: appProperties),
      content: markdown)
  }

  public func updateFile(
    id: String, markdown: Data, description: String, appProperties: [String: String]
  ) throws -> DriveFile {
    try record(.updateFile(id: id))
    var item = try requireItem(id)
    item.content = markdown
    item.file.description = description
    item.file.appProperties = appProperties
    return save(item)
  }

  public func moveFile(
    id: String, name: String?, description: String?, appProperties: [String: String]?,
    addParent: String?, removeParent: String?
  ) throws -> DriveFile {
    try record(.moveFile(id: id))
    var item = try requireItem(id)
    if let addParent {
      try requireFolder(addParent)
      item.file.parents.append(addParent)
    }
    if let removeParent { item.file.parents.removeAll { $0 == removeParent } }
    if let name { item.file.name = name }
    if let description { item.file.description = description }
    if let appProperties { item.file.appProperties = appProperties }
    return save(item)
  }

  public func trashFile(id: String) throws {
    try record(.trashFile(id: id))
    var item = try requireItem(id)
    item.trashed = true
    _ = save(item)
  }

  public func listFiles(appProperty key: String, value: String) throws -> [DriveFile] {
    try record(.listFiles)
    return items.values
      .filter { !$0.trashed && $0.file.appProperties[key] == value }
      .map(\.file)
      .sorted { $0.id < $1.id }
  }

  public func userEmail() throws -> String? {
    try record(.userEmail)
    return email
  }

  // MARK: - Internals

  private func record(_ call: Call) throws {
    calls.append(call)
    guard let index = failures.firstIndex(where: { $0.remaining > 0 && $0.matches(call) }) else {
      return
    }
    failures[index].remaining -= 1
    throw failures[index].error
  }

  private func requireItem(_ id: String) throws -> Item {
    guard let item = items[id], !item.trashed else {
      throw DriveError.http(status: 404, reason: "notFound", message: "File not found: \(id)")
    }
    return item
  }

  private func requireFolder(_ id: String) throws {
    guard try requireItem(id).file.isFolder else {
      throw DriveError.http(status: 400, reason: "invalidParent", message: "\(id) is not a folder")
    }
  }

  private func insert(_ file: DriveFile, content: Data?) -> DriveFile {
    var file = file
    file.id = "file-\(nextID)"
    nextID += 1
    return save(Item(file: file, content: content))
  }

  /// Stamps a strictly increasing modification time, so "most recently modified" is decidable.
  private func save(_ item: Item) -> DriveFile {
    var item = item
    tick += 1
    item.file.modifiedTime = Date(timeIntervalSince1970: 1_700_000_000 + tick)
    items[item.file.id] = item
    return item.file
  }
}
