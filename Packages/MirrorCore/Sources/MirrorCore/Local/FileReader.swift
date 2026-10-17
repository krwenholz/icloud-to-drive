import Foundation
import os

public enum FileReadResult: Equatable, Sendable {
  case content(PreparedContent)
  /// An iCloud placeholder. A download was requested; try again on a later pass.
  case notDownloaded
  case failed(String)
}

public protocol FileReading: Sendable {
  func read(_ url: URL) async -> FileReadResult
}

/// Reads through `NSFileCoordinator` so reads cooperate with iCloud's file provider.
public struct CoordinatedFileReader: FileReading {
  public typealias RawRead = @Sendable (URL) -> Result<Data, any Error>

  private let timeout: TimeInterval
  private let rawRead: RawRead

  /// `rawRead` is injectable so tests can simulate a coordinator that never returns.
  public init(timeout: TimeInterval = 30, rawRead: @escaping RawRead = Self.coordinatedRead) {
    self.timeout = timeout
    self.rawRead = rawRead
  }

  public func read(_ url: URL) async -> FileReadResult {
    if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
      .ubiquitousItemDownloadingStatus, status != .current
    {
      // Reading a placeholder would block on a download, so kick it off and come back later.
      try? FileManager.default.startDownloadingUbiquitousItem(at: url)
      return .notDownloaded
    }

    let rawRead = self.rawRead
    let timeout = self.timeout
    return await withCheckedContinuation { continuation in
      let finished = OSAllocatedUnfairLock(initialState: false)
      let finish: @Sendable (FileReadResult) -> Void = { result in
        let isFirst = finished.withLock { done in
          defer { done = true }
          return !done
        }
        if isFirst { continuation.resume(returning: result) }
      }
      // A coordinated read can block indefinitely while iCloud is busy, and a blocked
      // coordinator thread can't be cancelled. So we stop waiting and abandon the thread; it
      // finishes (or not) on its own and its late result is dropped.
      DispatchQueue.global(qos: .utility).async {
        switch rawRead(url) {
        case .success(let data): finish(.content(PreparedContent(markdown: data)))
        case .failure(let error): finish(.failed(error.localizedDescription))
        }
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
        finish(.failed("timed out after \(timeout) seconds waiting for a coordinated read"))
      }
    }
  }

  public static let coordinatedRead: RawRead = { url in
    var coordinationError: NSError?
    var result: Result<Data, any Error> = .failure(CocoaError(.fileReadUnknown))
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: url, options: .withoutChanges, error: &coordinationError
    ) { readURL in
      result = Result { try Data(contentsOf: readURL) }
    }
    if let coordinationError { return .failure(coordinationError) }
    return result
  }
}
