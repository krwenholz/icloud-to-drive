import Foundation

@testable import MirrorCore

/// Records what the view models ask for and lets tests push snapshots.
actor FakeMirrorService: MirrorService {
  enum Call: Equatable {
    case syncNow
    case setPaused(Bool)
    case applyPendingDeletions(UUID)
    case addRoot(String, String)
    case removeRoot(UUID, Bool)
    case updateRoot(RootConfig)
    case setUpdateStrategy(UpdateStrategy)
    case setDriveFolderName(String)
    case setFullSyncInterval(FullSyncInterval)
    case importClientFile(String)
    case signIn, signOut
  }

  private(set) var calls: [Call] = []
  private var current: MirrorSnapshot
  private var continuations: [AsyncStream<MirrorSnapshot>.Continuation] = []
  var failure: (any Error)?

  init(_ snapshot: MirrorSnapshot = MirrorSnapshot()) { current = snapshot }

  func push(_ snapshot: MirrorSnapshot) {
    current = snapshot
    for continuation in continuations { continuation.yield(snapshot) }
  }

  func fail(with error: (any Error)?) { failure = error }

  func snapshots() -> AsyncStream<MirrorSnapshot> {
    let (stream, continuation) = AsyncStream.makeStream(of: MirrorSnapshot.self)
    continuations.append(continuation)
    continuation.yield(current)
    return stream
  }

  private func check() throws { if let failure { throw failure } }

  func syncNow() { calls.append(.syncNow) }
  func setPaused(_ paused: Bool) { calls.append(.setPaused(paused)) }
  func applyPendingDeletions(root: UUID) { calls.append(.applyPendingDeletions(root)) }
  func addRoot(at url: URL, displayName: String) throws {
    calls.append(.addRoot(url.path, displayName))
    try check()
  }
  func removeRoot(_ id: UUID, trashDriveFolder: Bool) throws {
    calls.append(.removeRoot(id, trashDriveFolder))
    try check()
  }
  func updateRoot(_ config: RootConfig) throws {
    calls.append(.updateRoot(config))
    try check()
  }
  func setUpdateStrategy(_ strategy: UpdateStrategy) { calls.append(.setUpdateStrategy(strategy)) }
  func setDriveFolderName(_ name: String) { calls.append(.setDriveFolderName(name)) }
  func setFullSyncInterval(_ interval: FullSyncInterval) {
    calls.append(.setFullSyncInterval(interval))
  }
  func importClientFile(from url: URL) throws {
    calls.append(.importClientFile(url.path))
    try check()
  }
  func signIn() { calls.append(.signIn) }
  func signOut() { calls.append(.signOut) }
  func diagnostics() -> String { "diagnostics text" }
}

final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
  // @unchecked: tests touch this from one task at a time.
  var isEnabled = false
  var error: (any Error)?
  func setEnabled(_ enabled: Bool) throws {
    if let error { throw error }
    isEnabled = enabled
  }
}

/// Waits (yielding, plus short sleeps for file and actor work) until `condition` holds.
func eventually(
  timeout: Duration = .seconds(5), isolation: isolated (any Actor)? = #isolation,
  _ condition: () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}

func sampleRoot(
  _ name: String = "Notes", phase: RootPhase = .idle, held: Int = 0, heldPaths: [String] = [],
  convertToDocs: Bool = true
) -> RootSnapshot {
  RootSnapshot(
    config: RootConfig(displayName: name, path: "/tmp/\(name)", convertToDocs: convertToDocs),
    phase: phase, lastSuccessfulSync: Date(timeIntervalSince1970: 1_800_000_000),
    mirroredFiles: 12, heldDeletions: held, heldDeletionPaths: heldPaths)
}
