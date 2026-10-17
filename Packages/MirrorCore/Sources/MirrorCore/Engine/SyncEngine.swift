import Foundation

/// The outcome of one reconcile of one root.
public struct RootSyncReport: Equatable, Sendable {
  public var rootID: UUID
  public var finishedAt: Date
  /// Drive operations that succeeded.
  public var applied = 0
  /// Files that failed this time, with the reason. They are retried on the next reconcile.
  public var failures: [RelativePath: String] = [:]
  /// Files skipped until iCloud finishes downloading them.
  public var deferred: [RelativePath] = []
  public var heldDeletions = 0
  public var attention: SyncPlan.Attention?
  /// A failure that stopped the whole reconcile, such as Drive folder setup failing.
  public var error: String?

  /// Whether the reconcile ran to completion. Individual file failures don't count against it.
  public var completed: Bool {
    guard error == nil else { return false }
    if case .rootUnavailable = attention { return false }
    return true
  }
}

/// What the UI shows for a root between reconciles.
public struct RootStatus: Equatable, Sendable {
  public var mirroredFiles: Int
  public var lastSuccessfulSync: Date?
  public var failures: [RelativePath: String]
  public var driveFolderID: String?
}

/// Mirrors roots into Drive. Each root reconciles serially; different roots run concurrently,
/// sharing a global cap on in-flight Drive requests.
public actor SyncEngine {
  public typealias StateStore = JSONFileStore<MirrorState>

  private let drive: any DriveClient
  private let stateStore: StateStore
  private let scanner: FileScanner
  private let reader: any FileReading
  private let now: @Sendable () -> Date
  private let timeZone: TimeZone
  private let locale: Locale
  public var updateStrategy: UpdateStrategy

  private var loadedState: MirrorState?
  private var queues: [UUID: Task<RootSyncReport, Never>] = [:]
  private var mirrorFolderSetup: Task<String, any Error>?

  public init(
    drive: any DriveClient,
    stateStore: StateStore,
    reader: any FileReading = CoordinatedFileReader(),
    scanner: FileScanner = FileScanner(),
    updateStrategy: UpdateStrategy = .inPlace,
    maxConcurrentRequests: Int = 4,
    now: @escaping @Sendable () -> Date = { Date() },
    timeZone: TimeZone = .current,
    locale: Locale = .current
  ) {
    self.drive = LimitedDriveClient(drive, limit: maxConcurrentRequests)
    self.stateStore = stateStore
    self.reader = reader
    self.scanner = scanner
    self.updateStrategy = updateStrategy
    self.now = now
    self.timeZone = timeZone
    self.locale = locale
  }

  public func setUpdateStrategy(_ strategy: UpdateStrategy) { updateStrategy = strategy }

  /// Brings a root's Drive folder in line with its local folder. Calls for the same root queue
  /// behind each other; calls for different roots run concurrently.
  public func reconcile(_ root: RootConfig, applyPendingDeletions: Bool = false) async
    -> RootSyncReport
  {
    let previous = queues[root.id]
    let task = Task {
      _ = await previous?.value
      return await self.performReconcile(root, applyPendingDeletions: applyPendingDeletions)
    }
    queues[root.id] = task
    let report = await task.value
    if queues[root.id] == task { queues[root.id] = nil }
    return report
  }

  public func status(of rootID: UUID) -> RootStatus {
    let rootState = (try? state())?[root: rootID] ?? RootState()
    return RootStatus(
      mirroredFiles: rootState.files.count, lastSuccessfulSync: rootState.lastSuccessfulSync,
      failures: rootState.failures, driveFolderID: rootState.folderID)
  }

  /// The top-level `iCloud Mirror` folder, once it exists.
  public func mirrorFolderID() -> String? { (try? state())?.mirrorFolderID }

  /// Forgets a root, optionally trashing its Drive folder (and so every Doc in it).
  public func removeRoot(_ rootID: UUID, trashDriveFolder: Bool) async throws {
    _ = await queues[rootID]?.value
    var current = try state()
    if trashDriveFolder {
      var folderID = current[root: rootID].folderID
      if folderID == nil {
        folderID = try await drive.listFiles(root: rootID)
          .first { $0.appProperties[AppPropertyKey.kind] == DriveItemKind.rootFolder.rawValue }?.id
      }
      if let folderID { try await trashIgnoringMissing(folderID) }
    }
    current = try state()
    current.roots[rootID.uuidString] = nil
    try commit(current)
  }

  /// Discards a root's local state and recovers it from Drive.
  public func rebuildState(for root: RootConfig) async throws {
    _ = await queues[root.id]?.value
    try await rebuild(root)
  }

  // MARK: - Reconcile

  private func performReconcile(_ root: RootConfig, applyPendingDeletions: Bool) async
    -> RootSyncReport
  {
    var report = RootSyncReport(rootID: root.id, finishedAt: now())
    do {
      if try state().roots[root.id.uuidString] == nil {
        // No state for this root: either it's new or the state file was lost. Drive knows which.
        try await rebuild(root)
      }
      try await ensureFolders(for: root)
    } catch {
      report.error = "Couldn't prepare the Drive folder: \(error)"
      report.finishedAt = now()
      return report
    }

    let outcome = await scan(root)
    guard case .files(let scan) = outcome else {
      report.attention =
        Planner.plan(scan: outcome, state: RootState(), contentHashes: [:])
        .attention
      report.finishedAt = now()
      return report
    }

    await retryOrphans(root)

    var contents: [RelativePath: PreparedContent] = [:]
    let before = (try? state())?[root: root.id] ?? RootState()
    for path in Planner.pathsNeedingContent(scan: scan, state: before) {
      switch await reader.read(root.url.appending(path: path.value)) {
      case .content(let content): contents[path] = content
      case .notDownloaded: break
      case .failed(let message): report.failures[path] = "Couldn't read the file: \(message)"
      }
    }

    let plan = Planner.plan(
      scan: outcome, state: before, contentHashes: contents.mapValues(\.hash),
      allowMassDeletion: applyPendingDeletions)
    report.deferred = plan.deferred.filter { report.failures[$0] == nil }
    report.heldDeletions = plan.heldDeletions.count
    report.attention = plan.attention

    // Folders go one at a time, parents first; each later phase runs concurrently.
    let phases = Dictionary(grouping: plan.operations, by: \.phase).sorted { $0.key < $1.key }
    for (phase, operations) in phases {
      if phase == 0 {
        for operation in operations {
          await run(operation, root: root, contents: contents, report: &report)
        }
        continue
      }
      let loaded = contents
      var results: [(RelativePath?, String?)] = []
      await withTaskGroup(of: (RelativePath?, String?).self) { group in
        for operation in operations {
          group.addTask { await self.runConcurrently(operation, root: root, contents: loaded) }
        }
        for await result in group { results.append(result) }
      }
      for (path, failure) in results {
        if let path, let failure { report.failures[path] = failure } else { report.applied += 1 }
      }
    }

    report.finishedAt = now()
    finishReconcile(root, report: report, scanned: Set(scan.map(\.path)))
    await refreshStatusDoc(for: root, report: report)
    return report
  }

  private nonisolated func scan(_ root: RootConfig) async -> ScanOutcome {
    scanner.scan(root: root.url, filter: root.filter)
  }

  private func runConcurrently(
    _ operation: PlannedOperation, root: RootConfig, contents: [RelativePath: PreparedContent]
  ) async -> (RelativePath?, String?) {
    var report = RootSyncReport(rootID: root.id, finishedAt: now())
    await run(operation, root: root, contents: contents, report: &report)
    return (report.failures.first?.key ?? operation.path, report.failures.first?.value)
  }

  /// Runs one operation, saving state as soon as it succeeds so a crash mid-batch resumes
  /// instead of re-uploading.
  private func run(
    _ operation: PlannedOperation, root: RootConfig, contents: [RelativePath: PreparedContent],
    report: inout RootSyncReport
  ) async {
    do {
      try await execute(operation, root: root, contents: contents)
      if operation.phase == 0 { report.applied += 1 }
      if let path = operation.path { try update(root) { $0.failures[path] = nil } }
    } catch {
      let message = "\(error)"
      if let path = operation.path {
        report.failures[path] = message
        try? update(root) { $0.failures[path] = message }
      } else {
        report.error = report.error ?? message
      }
    }
  }

  private func execute(
    _ operation: PlannedOperation, root: RootConfig, contents: [RelativePath: PreparedContent]
  ) async throws {
    switch operation {
    case .createFolder(let directory):
      let parentDirectory = parentDirectory(of: directory)
      guard let parentID = try state()[root: root.id].folderID(forDirectory: parentDirectory)
      else { throw EngineError.missingFolder(parentDirectory) }
      let folder = try await drive.createFolder(
        name: directory.split(separator: "/").last.map(String.init) ?? directory,
        parentID: parentID,
        description: DriveDescription.folder(rootName: root.displayName, directory: directory),
        appProperties: [
          AppPropertyKey.root: root.id.uuidString,
          AppPropertyKey.pathHash: Hashing.sha256Hex(directory),
          AppPropertyKey.kind: DriveItemKind.folder.rawValue,
        ])
      try update(root) { $0.folders[directory] = folder.id }

    case .createDoc(let file, let hash):
      let content = try content(for: file.path, in: contents)
      let doc = try await createDoc(root: root, path: file.path, content: content)
      try update(root) {
        $0.files[file.path] = FileRecord(
          fileID: doc.id, contentHash: hash, size: file.size, modified: file.modified)
      }

    case .updateDoc(let file, let fileID, let hash):
      let content = try content(for: file.path, in: contents)
      let newID: String
      switch updateStrategy {
      case .inPlace:
        newID = try await drive.updateDoc(
          id: fileID, markdown: content.data,
          description: DriveDescription.doc(rootName: root.displayName, path: file.path),
          appProperties: docProperties(root, file.path, hash)
        ).id
      case .replace:
        newID = try await createDoc(root: root, path: file.path, content: content).id
      }
      try update(root) {
        $0.files[file.path] = FileRecord(
          fileID: newID, contentHash: hash, size: file.size, modified: file.modified)
        if newID != fileID { $0.orphanedFileIDs.append(fileID) }
      }
      if newID != fileID { await retryOrphans(root) }

    case .moveDoc(let source, let destination, let fileID):
      let rootState = try state()[root: root.id]
      let oldDirectory = source.directory
      let newDirectory = destination.path.directory
      var addParent: String?
      var removeParent: String?
      if oldDirectory != newDirectory {
        guard let newParent = rootState.folderID(forDirectory: newDirectory) else {
          throw EngineError.missingFolder(newDirectory)
        }
        addParent = newParent
        removeParent = rootState.folderID(forDirectory: oldDirectory)
      }
      guard let record = rootState.files[source] else { return }
      _ = try await drive.moveFile(
        id: fileID,
        name: source.docTitle == destination.path.docTitle ? nil : destination.path.docTitle,
        description: DriveDescription.doc(rootName: root.displayName, path: destination.path),
        appProperties: docProperties(root, destination.path, record.contentHash),
        addParent: addParent, removeParent: removeParent)
      try update(root) {
        $0.files[source] = nil
        $0.failures[source] = nil
        $0.files[destination.path] = FileRecord(
          fileID: fileID, contentHash: record.contentHash, size: destination.size,
          modified: destination.modified)
      }

    case .recordUnchanged(let file):
      try update(root) {
        $0.files[file.path]?.size = file.size
        $0.files[file.path]?.modified = file.modified
      }

    case .trashDoc(let path, let fileID):
      try await trashIgnoringMissing(fileID)
      try update(root) { $0.files[path] = nil }
    }
  }

  private func createDoc(root: RootConfig, path: RelativePath, content: PreparedContent)
    async throws -> DriveFile
  {
    guard let parentID = try state()[root: root.id].folderID(forDirectory: path.directory) else {
      throw EngineError.missingFolder(path.directory)
    }
    return try await drive.createDoc(
      markdown: content.data, name: path.docTitle, parentID: parentID,
      description: DriveDescription.doc(rootName: root.displayName, path: path),
      appProperties: docProperties(root, path, content.hash))
  }

  private func docProperties(_ root: RootConfig, _ path: RelativePath, _ hash: String)
    -> [String: String]
  {
    [
      AppPropertyKey.root: root.id.uuidString,
      AppPropertyKey.pathHash: path.pathHash,
      AppPropertyKey.contentHash: hash,
      AppPropertyKey.kind: DriveItemKind.doc.rawValue,
    ]
  }

  private func content(for path: RelativePath, in contents: [RelativePath: PreparedContent])
    throws -> PreparedContent
  {
    guard let content = contents[path] else { throw EngineError.contentUnavailable(path) }
    return content
  }

  private func trashIgnoringMissing(_ id: String) async throws {
    do {
      try await drive.trashFile(id: id)
    } catch DriveError.http(status: 404, _, _) {
      // Already gone, which is what we wanted.
    }
  }

  private func retryOrphans(_ root: RootConfig) async {
    guard let orphans = try? state()[root: root.id].orphanedFileIDs, !orphans.isEmpty else {
      return
    }
    for id in orphans {
      guard (try? await trashIgnoringMissing(id)) != nil else { continue }
      try? update(root) { $0.orphanedFileIDs.removeAll { $0 == id } }
    }
  }

  private func finishReconcile(
    _ root: RootConfig, report: RootSyncReport, scanned: Set<RelativePath>
  ) {
    try? update(root) { rootState in
      // Forget failures for files that no longer exist locally.
      rootState.failures = rootState.failures.filter { scanned.contains($0.key) }
      for (path, message) in report.failures { rootState.failures[path] = message }
      rootState.lastSuccessfulSync = report.finishedAt
    }
  }

  // MARK: - Folders and status

  private func ensureFolders(for root: RootConfig) async throws {
    let mirrorFolderID = try await ensureMirrorFolder()
    if try state()[root: root.id].folderID == nil {
      let folder = try await drive.createFolder(
        name: root.displayName, parentID: mirrorFolderID,
        description: DriveDescription.rootFolder(rootName: root.displayName),
        appProperties: [
          AppPropertyKey.root: root.id.uuidString,
          AppPropertyKey.kind: DriveItemKind.rootFolder.rawValue,
        ])
      try update(root) { $0.folderID = folder.id }
    }
  }

  /// Finds or creates `iCloud Mirror`. Roots reconciling at the same time share one attempt,
  /// or each would create its own folder.
  private func ensureMirrorFolder() async throws -> String {
    if let id = try state().mirrorFolderID { return id }
    if let mirrorFolderSetup { return try await mirrorFolderSetup.value }
    let setup = Task { try await self.findOrCreateMirrorFolder() }
    mirrorFolderSetup = setup
    defer { mirrorFolderSetup = nil }
    return try await setup.value
  }

  private func findOrCreateMirrorFolder() async throws -> String {
    let existing = try await drive.listFiles(
      appProperty: AppPropertyKey.kind, value: DriveItemKind.mirrorFolder.rawValue
    )
    .filter(\.isFolder)
    .min { ($0.modifiedTime ?? .distantPast) < ($1.modifiedTime ?? .distantPast) }
    var folderID = existing?.id
    if folderID == nil {
      folderID =
        try await drive.createFolder(
          name: AppIdentity.driveRootFolderName, parentID: nil,
          description: "Created by \(AppIdentity.displayName). The notes on iCloud are the "
            + "source of truth; this folder can be rebuilt from them.",
          appProperties: [AppPropertyKey.kind: DriveItemKind.mirrorFolder.rawValue]
        ).id
    }
    guard let folderID else { throw DriveError.invalidResponse("no mirror folder ID") }
    var current = try state()
    current.mirrorFolderID = folderID
    try commit(current)
    return folderID
  }

  private func refreshStatusDoc(for root: RootConfig, report: RootSyncReport) async {
    guard let rootState = try? state()[root: root.id], let folderID = rootState.folderID else {
      return
    }
    let changed = report.applied > 0 || !report.failures.isEmpty || report.attention != nil
    let stale = rootState.statusDocUpdatedAt.map {
      report.finishedAt.timeIntervalSince($0) >= StatusDoc.maxAge
    }
    guard changed || stale ?? true || rootState.statusDocID == nil else { return }

    let markdown = StatusDoc.markdown(
      StatusDoc.Content(
        rootName: root.displayName, lastSuccessfulSync: report.finishedAt,
        mirroredFiles: rootState.files.count, failures: rootState.failures,
        heldDeletions: report.heldDeletions, waitingForDownload: report.deferred.count),
      timeZone: timeZone, locale: locale)
    let data = Data(markdown.utf8)
    let description = "\(root.displayName) / \(StatusDoc.name)"
    let properties = [
      AppPropertyKey.root: root.id.uuidString,
      AppPropertyKey.kind: DriveItemKind.statusDoc.rawValue,
    ]
    do {
      let previousID = rootState.statusDocID
      let doc: DriveFile
      if let previousID, updateStrategy == .inPlace {
        doc = try await drive.updateDoc(
          id: previousID, markdown: data, description: description, appProperties: properties)
      } else {
        doc = try await drive.createDoc(
          markdown: data, name: StatusDoc.name, parentID: folderID, description: description,
          appProperties: properties)
      }
      try update(root) {
        $0.statusDocID = doc.id
        $0.statusDocUpdatedAt = report.finishedAt
        if let previousID, previousID != doc.id { $0.orphanedFileIDs.append(previousID) }
      }
      if let previousID, previousID != doc.id { await retryOrphans(root) }
    } catch DriveError.http(status: 404, _, _) {
      // The owner deleted the status Doc; make a new one next time.
      try? update(root) { $0.statusDocID = nil }
    } catch {
      // The status Doc is advisory; the next reconcile tries again.
    }
  }

  // MARK: - State

  /// Loads state on first use. A missing or unreadable file starts empty, which makes each
  /// root rebuild from Drive before it does anything else.
  private func state() throws -> MirrorState {
    if let loadedState { return loadedState }
    let state: MirrorState
    switch stateStore.load() {
    case .loaded(let loaded): state = loaded
    case .missing: state = MirrorState()
    case .corrupt:
      // Keep the bad file for diagnosis rather than silently overwriting it.
      let backup = stateStore.url.appendingPathExtension("corrupt")
      try? FileManager.default.removeItem(at: backup)
      try? FileManager.default.moveItem(at: stateStore.url, to: backup)
      state = MirrorState()
    }
    loadedState = state
    return state
  }

  private func commit(_ state: MirrorState) throws {
    loadedState = state
    try stateStore.save(state)
  }

  private func update(_ root: RootConfig, _ change: (inout RootState) -> Void) throws {
    var current = try state()
    change(&current[root: root.id])
    try commit(current)
  }

  /// Recovers a root's state from the appProperties and descriptions on its Drive files.
  private func rebuild(_ root: RootConfig) async throws {
    let files = try await drive.listFiles(root: root.id)
    func newestFirst(_ a: DriveFile, _ b: DriveFile) -> Bool {
      (a.modifiedTime ?? .distantPast) > (b.modifiedTime ?? .distantPast)
    }
    func kind(_ file: DriveFile) -> DriveItemKind? {
      file.appProperties[AppPropertyKey.kind].flatMap(DriveItemKind.init(rawValue:))
    }

    var rebuilt = RootState()
    var duplicates: [String] = []
    rebuilt.folderID = files.filter { kind($0) == .rootFolder }.sorted(by: newestFirst).first?.id

    let statusDocs = files.filter { kind($0) == .statusDoc }.sorted(by: newestFirst)
    rebuilt.statusDocID = statusDocs.first?.id
    duplicates += statusDocs.dropFirst().map(\.id)

    for folder in files.filter({ kind($0) == .folder }).sorted(by: newestFirst) {
      guard
        let directory = DriveDescription.recoverDirectory(
          from: folder.description, pathHash: folder.appProperties[AppPropertyKey.pathHash]),
        rebuilt.folders[directory] == nil
      else { continue }
      rebuilt.folders[directory] = folder.id
    }

    // If two Docs claim the same path, keep the most recently modified and trash the other.
    for doc in files.filter({ kind($0) == .doc }).sorted(by: newestFirst) {
      guard
        let path = DriveDescription.recoverPath(
          from: doc.description, pathHash: doc.appProperties[AppPropertyKey.pathHash]),
        let hash = doc.appProperties[AppPropertyKey.contentHash]
      else { continue }
      if rebuilt.files[path] != nil {
        duplicates.append(doc.id)
      } else {
        rebuilt.files[path] = FileRecord(fileID: doc.id, contentHash: hash)
      }
    }

    var current = try state()
    current[root: root.id] = rebuilt
    try commit(current)
    for id in duplicates { try? await trashIgnoringMissing(id) }
  }
}

public enum EngineError: Error, Equatable, CustomStringConvertible {
  case missingFolder(String)
  case contentUnavailable(RelativePath)

  public var description: String {
    switch self {
    case .missingFolder(let directory):
      "The Drive folder for \(directory.isEmpty ? "the root" : "'\(directory)'") doesn't exist yet"
    case .contentUnavailable(let path): "No content was read for \(path)"
    }
  }
}

extension PlannedOperation {
  /// The file an operation is about, used to attribute failures.
  var path: RelativePath? {
    switch self {
    case .createFolder: nil
    case .moveDoc(_, let file, _), .updateDoc(let file, _, _), .createDoc(let file, _),
      .recordUnchanged(let file):
      file.path
    case .trashDoc(let path, _): path
    }
  }
}
