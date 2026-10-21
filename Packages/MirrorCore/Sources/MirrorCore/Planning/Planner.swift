import Foundation

public struct ScannedFile: Equatable, Sendable {
  public var path: RelativePath
  public var size: Int64
  public var modified: Date

  public init(path: RelativePath, size: Int64, modified: Date) {
    self.path = path
    self.size = size
    self.modified = modified
  }
}

public enum PlannedOperation: Equatable, Sendable {
  case createFolder(directory: String)
  case moveDoc(from: RelativePath, to: ScannedFile, fileID: String)
  case updateDoc(ScannedFile, fileID: String, contentHash: String)
  /// The root's "convert to Google Docs" setting changed since this file was uploaded. The file
  /// is created again in the new format and the old copy trashed. That is a replacement, not a
  /// deletion, so it never counts toward the mass-deletion guard.
  case reformatDoc(ScannedFile, fileID: String, contentHash: String)
  case createDoc(ScannedFile, contentHash: String)
  /// The file's size or modification time changed but its content didn't. Only state changes.
  case recordUnchanged(ScannedFile)
  case trashDoc(RelativePath, fileID: String)

  /// Execution order: folders before the files inside them, moves before creates, trashes last.
  var phase: Int {
    switch self {
    case .createFolder: 0
    case .moveDoc: 1
    case .updateDoc, .reformatDoc: 2
    case .createDoc: 3
    case .recordUnchanged: 4
    case .trashDoc: 5
    }
  }
}

public struct SyncPlan: Equatable, Sendable {
  public var operations: [PlannedOperation] = []
  /// Trashes withheld by the mass-deletion guard until the owner applies them.
  public var heldDeletions: [PlannedOperation] = []
  /// Files that needed reading but had no content available yet (e.g. not downloaded).
  public var deferred: [RelativePath] = []
  /// Why the root needs the owner's attention, if it does.
  public var attention: Attention?

  public enum Attention: Equatable, Sendable {
    case rootUnavailable(String)
    case massDeletion(pending: Int, mirrored: Int)
  }
}

public enum ScanOutcome: Equatable, Sendable {
  case files([ScannedFile])
  case unavailable(reason: String)
}

/// Turns a root's scan results and state into Drive operations. Pure and synchronous.
public enum Planner {
  /// The guard holds deletions above this share of mirrored files...
  public static let massDeletionFraction = 0.25
  /// ...as long as they're also more than this many files.
  public static let massDeletionMinimum = 10

  /// Files whose content must be read and hashed before planning: new files, files whose
  /// size or modification time changed, and files uploaded in the wrong format. Everything
  /// else is skipped without being read.
  public static func pathsNeedingContent(
    scan: [ScannedFile], state: RootState, convertToDocs: Bool = true,
    skipping: Set<RelativePath> = []
  ) -> [RelativePath] {
    scan.filter { file in
      guard !skipping.contains(file.path) else { return false }
      guard let record = state.files[file.path] else { return true }
      return !statMatches(record, file) || record.converted != convertToDocs
    }.map(\.path).sorted()
  }

  /// - Parameter skipping: files left alone this time, such as ones that have been failing for
  ///   too long. They still count as present, so skipping never causes a trash.
  /// - Parameter contentHashes: prepared-content hashes for `pathsNeedingContent`. A path with no
  ///   hash is deferred to a later pass, and never treated as deleted.
  public static func plan(
    scan outcome: ScanOutcome,
    state: RootState,
    contentHashes: [RelativePath: String],
    convertToDocs: Bool = true,
    skipping: Set<RelativePath> = [],
    allowMassDeletion: Bool = false
  ) -> SyncPlan {
    guard case .files(let scan) = outcome else {
      if case .unavailable(let reason) = outcome {
        return SyncPlan(attention: .rootUnavailable(reason))
      }
      return SyncPlan()
    }

    var plan = SyncPlan()
    var operations: [PlannedOperation] = []
    var additions: [(file: ScannedFile, hash: String)] = []

    for file in scan.sorted(by: { $0.path < $1.path }) where !skipping.contains(file.path) {
      let record = state.files[file.path]
      if let record, statMatches(record, file), record.converted == convertToDocs { continue }
      guard let hash = contentHashes[file.path] else {
        plan.deferred.append(file.path)
        continue
      }
      switch record {
      case .some(let record) where record.converted != convertToDocs:
        operations.append(.reformatDoc(file, fileID: record.fileID, contentHash: hash))
      case .some(let record) where record.contentHash == hash:
        operations.append(.recordUnchanged(file))
      case .some(let record):
        operations.append(.updateDoc(file, fileID: record.fileID, contentHash: hash))
      case .none:
        additions.append((file, hash))
      }
    }

    let scannedPaths = Set(scan.map(\.path))
    var missing = state.files.keys.filter { !scannedPaths.contains($0) }.sorted()

    // A file that vanished from one path and appeared at another with the same content is a
    // move. Moving keeps the Drive file ID, so existing links to the Doc keep working.
    for (file, hash) in additions {
      let candidates = missing.filter { state.files[$0]?.contentHash == hash }
      let source =
        candidates.first { $0.fileName == file.path.fileName } ?? candidates.first
      if let source, let record = state.files[source] {
        missing.removeAll { $0 == source }
        operations.append(.moveDoc(from: source, to: file, fileID: record.fileID))
      } else {
        operations.append(.createDoc(file, contentHash: hash))
      }
    }

    let trashes = missing.compactMap { path in
      state.files[path].map { PlannedOperation.trashDoc(path, fileID: $0.fileID) }
    }
    let mirrored = state.files.count
    let isMassDeletion =
      Double(trashes.count) > Double(mirrored) * massDeletionFraction
      && trashes.count > massDeletionMinimum
    if isMassDeletion && !allowMassDeletion {
      plan.heldDeletions = trashes
      plan.attention = .massDeletion(pending: trashes.count, mirrored: mirrored)
    } else {
      operations += trashes
    }

    operations += foldersNeeded(by: operations, state: state).map {
      .createFolder(directory: $0)
    }
    plan.operations = operations.enumerated()
      .sorted { ($0.element.phase, $0.offset) < ($1.element.phase, $1.offset) }
      .map(\.element)
    return plan
  }

  private static func statMatches(_ record: FileRecord, _ file: ScannedFile) -> Bool {
    record.size == file.size && record.modified == file.modified
  }

  /// Directories that files are being placed into but that don't have a Drive folder yet,
  /// parents before children.
  private static func foldersNeeded(by operations: [PlannedOperation], state: RootState)
    -> [String]
  {
    var needed = Set<String>()
    for operation in operations {
      let destination: RelativePath
      switch operation {
      case .createDoc(let file, _), .moveDoc(_, let file, _): destination = file.path
      default: continue
      }
      for directory in directoryAndAncestors(destination.directory)
      where state.folders[directory] == nil {
        needed.insert(directory)
      }
    }
    return needed.sorted {
      let depths = ($0.split(separator: "/").count, $1.split(separator: "/").count)
      return depths.0 != depths.1 ? depths.0 < depths.1 : $0 < $1
    }
  }
}
