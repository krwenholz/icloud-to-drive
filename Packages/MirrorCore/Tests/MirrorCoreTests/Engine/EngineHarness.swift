import Foundation
import Testing

@testable import MirrorCore

/// Local folders, a fake Drive, and an engine wired together in a temp directory.
struct EngineHarness {
  let base: URL
  let drive = InMemoryDriveClient()
  let clock = TestClock()
  var paths: AppPaths { AppPaths(applicationSupport: base.appending(path: "Support")) }

  init() throws {
    base = FileManager.default.temporaryDirectory
      .appending(path: "EngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: base) }

  func makeEngine(
    strategy: UpdateStrategy = .inPlace, reader: any FileReading = CoordinatedFileReader(),
    drive: (any DriveClient)? = nil, maxConcurrentRequests: Int = 4
  ) -> SyncEngine {
    let clock = clock
    return SyncEngine(
      drive: drive ?? self.drive, stateStore: JSONFileStore(url: paths.stateFile),
      reader: reader, updateStrategy: strategy, maxConcurrentRequests: maxConcurrentRequests,
      now: { clock.now }, timeZone: TimeZone(identifier: "America/Los_Angeles")!,
      locale: Locale(identifier: "en_US_POSIX"))
  }

  func makeRoot(_ name: String = "Notes", files: [String: String] = [:]) throws -> RootConfig {
    let url = base.appending(path: "roots/\(name)-\(UUID().uuidString.prefix(4))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let root = RootConfig(displayName: name, path: url.path)
    for (path, text) in files { try write(root, path, text) }
    return root
  }

  func write(_ root: RootConfig, _ path: String, _ text: String) throws {
    let url = root.url.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func remove(_ root: RootConfig, _ path: String) throws {
    try FileManager.default.removeItem(at: root.url.appending(path: path))
  }

  func move(_ root: RootConfig, _ from: String, _ to: String) throws {
    let destination = root.url.appending(path: to)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: root.url.appending(path: from), to: destination)
  }

  /// The Drive tree under `iCloud Mirror`, as sorted paths with `/` on folders.
  func tree(_ engine: SyncEngine) async throws -> [String] {
    let mirror = try #require(await engine.mirrorFolderID())
    return await drive.treeListing(under: mirror)
  }

  /// Docs (not folders) under `iCloud Mirror` with their uploaded text.
  func docs(_ engine: SyncEngine) async throws -> [String: String] {
    let mirror = try #require(await engine.mirrorFolderID())
    return await drive.tree(under: mirror).compactMapValues { item in
      item.file.isFolder ? nil : item.content.map { String(decoding: $0, as: UTF8.self) }
    }
  }

  func docID(_ engine: SyncEngine, _ path: String) async throws -> String {
    let mirror = try #require(await engine.mirrorFolderID())
    return try #require(await drive.tree(under: mirror)[path]).file.id
  }

  /// Calls that changed Drive content, ignoring listings and the status Doc.
  func contentCalls(since start: Int = 0) async -> [InMemoryDriveClient.Call] {
    let calls = await drive.calls.dropFirst(start)
    var result: [InMemoryDriveClient.Call] = []
    for call in calls {
      switch call {
      case .listFiles, .userEmail: continue
      case .createDoc(name: StatusDoc.name): continue
      case .updateDoc(let id):
        if await drive.item(id)?.file.name == StatusDoc.name { continue }
        result.append(call)
      default: result.append(call)
      }
    }
    return result
  }
}

/// Reports chosen paths as still downloading from iCloud.
struct PartiallyDownloadedReader: FileReading {
  let pending: Set<String>
  let base = CoordinatedFileReader()

  func read(_ url: URL) async -> FileReadResult {
    pending.contains(url.lastPathComponent) ? .notDownloaded : await base.read(url)
  }
}
