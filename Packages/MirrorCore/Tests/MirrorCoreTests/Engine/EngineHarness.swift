import Foundation
import Testing
import os

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
    strategy: UpdateStrategy = .inPlace, driveFolderName: String = AppIdentity.driveRootFolderName,
    reader: any FileReading = CoordinatedFileReader(),
    drive: (any DriveClient)? = nil, maxConcurrentRequests: Int = 4,
    machineName: String? = "Test Mac"
  ) -> SyncEngine {
    let clock = clock
    return SyncEngine(
      drive: drive ?? self.drive, stateStore: JSONFileStore(url: paths.stateFile),
      reader: reader, updateStrategy: strategy, driveFolderName: driveFolderName,
      machineName: machineName, maxConcurrentRequests: maxConcurrentRequests,
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
      case .createFile(name: StatusDoc.name): continue
      case .updateFile(let id):
        if await drive.item(id)?.file.name == StatusDoc.name { continue }
        result.append(call)
      default: result.append(call)
      }
    }
    return result
  }
}

/// A reader whose failures tests switch on and off, and which remembers what it was asked to
/// read. Files are matched by name, so use flat test trees.
final class ScriptedReader: FileReading, Sendable {
  private let failing = OSAllocatedUnfairLock(initialState: Set<String>())
  private let reads = OSAllocatedUnfairLock(initialState: [String]())
  private let base = CoordinatedFileReader()

  func setFailing(_ names: Set<String>) { failing.withLock { $0 = names } }
  var readNames: [String] { reads.withLock { $0 } }
  func clearReads() { reads.withLock { $0 = [] } }

  func read(_ url: URL) async -> FileReadResult {
    let name = url.lastPathComponent
    reads.withLock { $0.append(name) }
    if failing.withLock({ $0.contains(name) }) { return .failed("simulated read failure") }
    return await base.read(url)
  }
}

/// Moves the test clock forward on every read, to give a reconcile a measurable duration.
struct ClockAdvancingReader: FileReading {
  let clock: TestClock
  let seconds: TimeInterval
  func read(_ url: URL) async -> FileReadResult {
    clock.advance(by: seconds)
    return await CoordinatedFileReader().read(url)
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
