import Foundation

/// A counting semaphore for async code.
actor AsyncLimiter {
  private let limit: Int
  private var running = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) { self.limit = max(limit, 1) }

  var waitingCount: Int { waiters.count }

  func acquire() async {
    if running < limit {
      running += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      running -= 1
    } else {
      // Hand the slot straight to the next waiter; `running` stays the same.
      waiters.removeFirst().resume()
    }
  }

  func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    await acquire()
    do {
      let result = try await operation()
      release()
      return result
    } catch {
      release()
      throw error
    }
  }
}

/// Wraps a `DriveClient` so all roots together keep at most `limit` requests in flight.
struct LimitedDriveClient: DriveClient {
  let base: any DriveClient
  let limiter: AsyncLimiter

  init(_ base: any DriveClient, limit: Int) {
    self.base = base
    limiter = AsyncLimiter(limit: limit)
  }

  func createFolder(
    name: String, parentID: String?, description: String?, appProperties: [String: String]
  ) async throws -> DriveFile {
    try await limiter.run {
      try await base.createFolder(
        name: name, parentID: parentID, description: description, appProperties: appProperties)
    }
  }

  func createDoc(
    markdown: Data, name: String, parentID: String, description: String,
    appProperties: [String: String]
  ) async throws -> DriveFile {
    try await limiter.run {
      try await base.createDoc(
        markdown: markdown, name: name, parentID: parentID, description: description,
        appProperties: appProperties)
    }
  }

  func updateDoc(id: String, markdown: Data, description: String, appProperties: [String: String])
    async throws -> DriveFile
  {
    try await limiter.run {
      try await base.updateDoc(
        id: id, markdown: markdown, description: description, appProperties: appProperties)
    }
  }

  func moveFile(
    id: String, name: String?, description: String?, appProperties: [String: String]?,
    addParent: String?, removeParent: String?
  ) async throws -> DriveFile {
    try await limiter.run {
      try await base.moveFile(
        id: id, name: name, description: description, appProperties: appProperties,
        addParent: addParent, removeParent: removeParent)
    }
  }

  func trashFile(id: String) async throws {
    try await limiter.run { try await base.trashFile(id: id) }
  }

  func listFiles(appProperty key: String, value: String) async throws -> [DriveFile] {
    try await limiter.run { try await base.listFiles(appProperty: key, value: value) }
  }

  func userEmail() async throws -> String? {
    try await limiter.run { try await base.userEmail() }
  }
}
