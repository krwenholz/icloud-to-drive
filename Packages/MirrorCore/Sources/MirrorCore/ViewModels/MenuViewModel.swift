import Foundation
import Observation

/// The overall state the menu bar icon reflects.
public enum OverallState: Equatable, Sendable {
  case idle, syncing, error, paused

  public var symbolName: String {
    switch self {
    case .idle: "checkmark.icloud"
    case .syncing: "arrow.triangle.2.circlepath.icloud"
    case .error: "exclamationmark.icloud"
    case .paused: "pause.circle"
    }
  }
}

/// One root's line in the menu.
public struct RootLine: Equatable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var detail: String?
}

/// Backs the menu bar menu. Views only render it and call its actions.
@MainActor @Observable
public final class MenuViewModel {
  public private(set) var snapshot = MirrorSnapshot()
  private let service: any MirrorService
  private let now: @Sendable () -> Date
  private let locale: Locale
  private let copyToPasteboard: @MainActor (String) -> Void
  private let openURL: @MainActor (URL) -> Void
  @ObservationIgnored private var listener: Task<Void, Never>?

  public init(
    service: any MirrorService, now: @escaping @Sendable () -> Date = { Date() },
    locale: Locale = .current,
    copyToPasteboard: @escaping @MainActor (String) -> Void,
    openURL: @escaping @MainActor (URL) -> Void
  ) {
    self.service = service
    self.now = now
    self.locale = locale
    self.copyToPasteboard = copyToPasteboard
    self.openURL = openURL
  }

  /// Starts following the service's snapshots. Returns once the first one has arrived.
  public func start() async {
    listener = await followSnapshots(of: service) { [weak self] in self?.snapshot = $0 }
  }

  public func stop() { listener?.cancel() }

  // MARK: - Display

  public var overallState: OverallState {
    if snapshot.isPaused { return .paused }
    if snapshot.roots.contains(where: { $0.phase == .syncing }) { return .syncing }
    let hasProblem = snapshot.roots.contains { root in
      switch root.phase {
      case .error, .needsAttention: true
      default: false
      }
    }
    if hasProblem || snapshot.message != nil { return .error }
    switch snapshot.account {
    case .signedIn, .loading: return .idle
    default: break
    }
    return snapshot.roots.isEmpty ? .idle : .error
  }

  public var lastSyncText: String {
    guard let last = snapshot.lastSuccessfulSync else { return "Not synced yet" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.locale = locale
    return "Last synced \(formatter.localizedString(for: last, relativeTo: now()))"
  }

  public var rootLines: [RootLine] {
    snapshot.roots.map { root in
      let status: String
      var detail: String?
      switch root.phase {
      case .idle: status = "\(root.mirroredFiles) notes"
      case .syncing: status = "Syncing…"
      case .needsAttention(let message):
        status = "Needs attention"
        detail = heldDeletionsDetail(root) ?? message
      case .error(let message):
        status = "Error"
        detail = message
      }
      return RootLine(id: root.id, title: "\(root.config.displayName): \(status)", detail: detail)
    }
  }

  /// How many held paths the menu names before saying "and N more".
  static let namedHeldPaths = 3

  /// Shows what the guard is holding, so the owner can decide before choosing Apply.
  private func heldDeletionsDetail(_ root: RootSnapshot) -> String? {
    guard root.heldDeletions > 0, !root.heldDeletionPaths.isEmpty else { return nil }
    let noun = root.config.convertToDocs ? "Doc" : "file"
    let count = "\(root.heldDeletions) \(noun)\(root.heldDeletions == 1 ? "" : "s")"
    let named = Array(root.heldDeletionPaths.prefix(Self.namedHeldPaths))
    let unnamed = root.heldDeletions - named.count
    var names = named.joined(separator: ", ")
    if unnamed > 0 {
      names += ", and \(unnamed) more"
    } else if named.count > 1 {
      names = named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
    }
    return "Would trash \(count): \(names). Choose Apply Pending Deletions if that's right."
  }

  /// Account problems that block syncing, shown above the roots.
  public var accountNotice: String? {
    if let message = snapshot.message { return message }
    switch snapshot.account {
    case .loading: return nil
    case .needsClientFile: return "Import your Google client file in Settings."
    case .signedOut: return "Sign in to Google in Settings."
    case .signedIn: return snapshot.roots.isEmpty ? "Add a folder in Settings." : nil
    }
  }

  public var showsApplyPendingDeletions: Bool {
    snapshot.roots.contains { $0.heldDeletions > 0 }
  }

  public var pauseTitle: String { snapshot.isPaused ? "Resume" : "Pause" }

  public var canOpenDrive: Bool { snapshot.mirrorFolderURL != nil }

  // MARK: - Actions

  public func syncNow() async { await service.syncNow() }

  public func togglePause() async { await service.setPaused(!snapshot.isPaused) }

  public func applyPendingDeletions() async {
    for root in snapshot.roots where root.heldDeletions > 0 {
      await service.applyPendingDeletions(root: root.id)
    }
  }

  public func openInDrive() {
    guard let url = snapshot.mirrorFolderURL else { return }
    openURL(url)
  }

  public func copyDiagnostics() async {
    copyToPasteboard(await service.diagnostics())
  }
}
