import Foundation
import Observation

/// Turns launch at login on and off; `SMAppService.mainApp` in the app.
public protocol LoginItemControlling: Sendable {
  var isEnabled: Bool { get }
  func setEnabled(_ enabled: Bool) throws
}

/// Backs the Settings window's Account, Folders, and General sections.
@MainActor @Observable
public final class SettingsViewModel {
  public private(set) var snapshot = MirrorSnapshot()
  /// The last action's failure, shown inline until the next action.
  public private(set) var errorMessage: String?
  public private(set) var launchAtLogin: Bool
  public private(set) var isSigningIn = false

  private let service: any MirrorService
  private let loginItem: any LoginItemControlling
  @ObservationIgnored private var listener: Task<Void, Never>?

  public init(service: any MirrorService, loginItem: any LoginItemControlling) {
    self.service = service
    self.loginItem = loginItem
    launchAtLogin = loginItem.isEnabled
  }

  /// Starts following the service's snapshots. Returns once the first one has arrived.
  public func start() async {
    listener = await followSnapshots(of: service) { [weak self] in self?.snapshot = $0 }
  }

  public func stop() { listener?.cancel() }

  // MARK: - Account

  public var accountDescription: String {
    switch snapshot.account {
    case .needsClientFile: "No Google client file imported"
    case .signedOut: "Not signed in"
    case .signedIn(let email?): "Signed in as \(email)"
    case .signedIn(nil): "Signed in"
    }
  }

  public var canSignIn: Bool {
    if case .signedOut = snapshot.account { return !isSigningIn }
    return false
  }

  public var isSignedIn: Bool {
    if case .signedIn = snapshot.account { return true }
    return false
  }

  public func importClientFile(_ url: URL) async {
    await perform { try await self.service.importClientFile(from: url) }
  }

  public func signIn() async {
    isSigningIn = true
    defer { isSigningIn = false }
    errorMessage = nil
    await service.signIn()
  }

  public func signOut() async { await service.signOut() }

  // MARK: - Folders

  public var roots: [RootConfig] { snapshot.roots.map(\.config) }

  /// The name a new root gets unless the owner changes it.
  public nonisolated static func defaultDisplayName(for url: URL) -> String {
    url.standardizedFileURL.lastPathComponent
  }

  public func addRoot(_ url: URL, displayName: String? = nil) async {
    let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = trimmed.isEmpty ? Self.defaultDisplayName(for: url) : trimmed
    let path = url.resolvingSymlinksInPath().path
    if roots.contains(where: { $0.url.resolvingSymlinksInPath().path == path }) {
      errorMessage = "\(url.path) is already being mirrored."
      return
    }
    await perform { try await self.service.addRoot(at: url, displayName: name) }
  }

  public func removeRoot(_ id: UUID, trashDriveFolder: Bool) async {
    await perform { try await self.service.removeRoot(id, trashDriveFolder: trashDriveFolder) }
  }

  /// Patterns are edited as text, one per line. Blank lines are ignored.
  public static func patternsText(_ patterns: [GlobPattern]) -> String {
    patterns.map(\.pattern).joined(separator: "\n")
  }

  public static func parsePatterns(_ text: String) -> [GlobPattern] {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .map(GlobPattern.init)
  }

  public func updatePatterns(for id: UUID, include: String, exclude: String) async {
    guard var root = roots.first(where: { $0.id == id }) else { return }
    let includes = Self.parsePatterns(include)
    guard !includes.isEmpty else {
      errorMessage = "Add at least one include pattern, such as **/*.md."
      return
    }
    root.filter = PathFilter(include: includes, exclude: Self.parsePatterns(exclude))
    await perform { try await self.service.updateRoot(root) }
  }

  public func rename(_ id: UUID, to name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var root = roots.first(where: { $0.id == id }), !trimmed.isEmpty else { return }
    root.displayName = trimmed
    await perform { try await self.service.updateRoot(root) }
  }

  // MARK: - General

  public func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try loginItem.setEnabled(enabled)
      errorMessage = nil
    } catch {
      errorMessage = "Couldn't change launch at login: \(error.localizedDescription)"
    }
    launchAtLogin = loginItem.isEnabled
  }

  public func setUpdateStrategy(_ strategy: UpdateStrategy) async {
    await service.setUpdateStrategy(strategy)
  }

  /// An empty name goes back to the default.
  public func setDriveFolderName(_ name: String) async {
    await service.setDriveFolderName(name)
  }

  private func perform(_ action: @escaping () async throws -> Void) async {
    do {
      try await action()
      errorMessage = nil
    } catch {
      errorMessage = "\(error.localizedDescription)"
    }
  }
}
