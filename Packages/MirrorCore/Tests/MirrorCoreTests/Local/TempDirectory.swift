import Foundation

/// A unique scratch directory, removed by `remove()`; tests call it in a `defer`.
struct TempDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("MirrorCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: url) }

  @discardableResult
  func write(_ relative: String, _ text: String = "hello") throws -> URL {
    let file = url.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
    return file
  }
}
