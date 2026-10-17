import Foundation

/// What the coordinator needs from the sync engine; `SyncEngine` is the real one.
public protocol ReconcileEngine: Sendable {
  func reconcile(_ root: RootConfig, applyPendingDeletions: Bool) async -> RootSyncReport
  func removeRoot(_ rootID: UUID, trashDriveFolder: Bool) async throws
  func status(of rootID: UUID) async -> RootStatus
  func mirrorFolderID() async -> String?
  func setUpdateStrategy(_ strategy: UpdateStrategy) async
}

extension SyncEngine: ReconcileEngine {}

/// What the coordinator needs from sign-in; `GoogleAuth` is the real one.
public protocol AuthSession: AccessTokenProvider {
  var isSignedIn: Bool { get async }
  func signIn(openBrowser: @Sendable (URL) async -> Void) async throws
  func signOut() async throws
}

extension GoogleAuth: AuthSession {}

public protocol FolderWatching: Sendable {
  func start(roots: [WatchedRoot], handler: @escaping @Sendable ([FolderEvent]) -> Void) async
  func stop() async
}

extension FolderWatcher: FolderWatching {}
