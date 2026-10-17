import Foundation
import os

@testable import MirrorCore

/// Collects what a command prints.
final class OutputLog: Sendable {
  private let lines = OSAllocatedUnfairLock(initialState: [String]())
  func append(_ line: String) { lines.withLock { $0.append(line) } }
  var text: String { lines.withLock { $0.joined(separator: "\n") } }
}

struct CLIHarness {
  let base: URL
  let drive: InMemoryDriveClient
  let out = OutputLog()
  let err = OutputLog()
  var paths: AppPaths { AppPaths(applicationSupport: base.appending(path: "Support")) }

  init(base: URL? = nil, drive: InMemoryDriveClient = InMemoryDriveClient()) throws {
    self.drive = drive
    if let base {
      self.base = base
      return
    }
    self.base = FileManager.default.temporaryDirectory
      .appending(path: "CLITests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: self.base, withIntermediateDirectories: true)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: base) }

  /// A folder of Markdown files under the temp directory.
  func makeFolder(_ name: String = "notes", files: [String: String]) throws -> URL {
    let folder = base.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (path, text) in files { try write(folder, path, text) }
    return folder
  }

  func write(_ folder: URL, _ path: String, _ text: String) throws {
    let url = folder.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func runner(email: String? = "me@example.com") -> CLIRunner {
    let drive = drive
    let out = out
    let err = err
    return CLIRunner(
      environment: CLIEnvironment(
        paths: paths, out: { out.append($0) }, err: { err.append($0) },
        makeDrive: { drive }, signIn: { email }))
  }
}
