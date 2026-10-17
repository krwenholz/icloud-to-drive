import Foundation

/// How one root is doing, as the menu shows it.
public enum RootPhase: Equatable, Sendable {
  case idle
  case syncing
  /// Deletions are held by the mass-deletion guard.
  case needsAttention(String)
  case error(String)
}

public struct RootSnapshot: Equatable, Identifiable, Sendable {
  public var id: UUID
  public var config: RootConfig
  public var phase: RootPhase
  public var lastSuccessfulSync: Date?
  public var mirroredFiles: Int
  public var failingFiles: Int
  public var heldDeletions: Int

  public init(
    config: RootConfig, phase: RootPhase = .idle, lastSuccessfulSync: Date? = nil,
    mirroredFiles: Int = 0, failingFiles: Int = 0, heldDeletions: Int = 0
  ) {
    id = config.id
    self.config = config
    self.phase = phase
    self.lastSuccessfulSync = lastSuccessfulSync
    self.mirroredFiles = mirroredFiles
    self.failingFiles = failingFiles
    self.heldDeletions = heldDeletions
  }
}

public enum AccountState: Equatable, Sendable {
  /// `google-client.json` hasn't been imported yet.
  case needsClientFile
  case signedOut
  /// Email is nil when the `drive.file` scope can't read it.
  case signedIn(email: String?)
}

/// Everything the UI renders, published as a whole on every change.
public struct MirrorSnapshot: Equatable, Sendable {
  public var roots: [RootSnapshot] = []
  public var account: AccountState = .signedOut
  public var isPaused = false
  public var updateStrategy: UpdateStrategy = .inPlace
  public var mirrorFolderID: String?
  /// A problem that isn't about one root, such as sign-in failing.
  public var message: String?

  public init() {}

  public var lastSuccessfulSync: Date? { roots.compactMap(\.lastSuccessfulSync).max() }

  public var mirrorFolderURL: URL? {
    mirrorFolderID.map { URL(string: "https://drive.google.com/drive/folders/\($0)")! }
  }
}

/// The app's interface to syncing. The view models depend on this, not on the coordinator,
/// so they can be tested against a fake.
public protocol MirrorService: Sendable {
  func snapshots() async -> AsyncStream<MirrorSnapshot>
  func syncNow() async
  func setPaused(_ paused: Bool) async
  func applyPendingDeletions(root: UUID) async
  func addRoot(at url: URL, displayName: String) async throws
  func removeRoot(_ id: UUID, trashDriveFolder: Bool) async throws
  func updateRoot(_ config: RootConfig) async throws
  func setUpdateStrategy(_ strategy: UpdateStrategy) async
  func importClientFile(from url: URL) async throws
  func signIn() async
  func signOut() async
  func diagnostics() async -> String
}
