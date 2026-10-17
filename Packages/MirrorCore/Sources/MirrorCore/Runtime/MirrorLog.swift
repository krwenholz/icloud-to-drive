import Foundation
import os

/// Logs to the unified log and to a size-capped file in Application Support, so problems are
/// visible after the fact and can be copied into a diagnostics report.
public final class MirrorLog: Sendable {
  public static let subsystem = AppIdentity.bundleIdentifier

  private let logger: Logger
  private let file: RollingLogFile?
  private let now: @Sendable () -> Date

  public init(
    category: String = "sync", file: RollingLogFile? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    logger = Logger(subsystem: Self.subsystem, category: category)
    self.file = file
    self.now = now
  }

  public func info(_ message: String) {
    logger.info("\(message, privacy: .public)")
    write("INFO", message)
  }

  public func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
    write("ERROR", message)
  }

  public func recentLines(_ count: Int = 200) -> [String] {
    file?.recentLines(count) ?? []
  }

  private func write(_ level: String, _ message: String) {
    let timestamp = now().formatted(.iso8601)
    file?.append("\(timestamp) \(level) \(message)")
  }
}

/// A log file that rolls over to `<name>.1` once it passes `maxBytes`, so it never grows past
/// about twice that.
public final class RollingLogFile: @unchecked Sendable {
  // @unchecked: all file access is serialized by `lock`.
  private let url: URL
  private let maxBytes: Int
  private let lock = NSLock()

  public init(url: URL, maxBytes: Int = 1_000_000) {
    self.url = url
    self.maxBytes = maxBytes
  }

  var rolledURL: URL { url.appendingPathExtension("1") }

  public func append(_ line: String) {
    lock.withLock {
      let fileManager = FileManager.default
      try? fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = Data((line.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
      if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int,
        size + data.count > maxBytes
      {
        try? fileManager.removeItem(at: rolledURL)
        try? fileManager.moveItem(at: url, to: rolledURL)
      }
      guard let handle = try? FileHandle(forWritingTo: url) else {
        try? data.write(to: url)
        return
      }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    }
  }

  public func recentLines(_ count: Int) -> [String] {
    lock.withLock {
      let text = [rolledURL, url]
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        .joined()
      return Array(text.split(separator: "\n").suffix(count).map(String.init))
    }
  }
}
