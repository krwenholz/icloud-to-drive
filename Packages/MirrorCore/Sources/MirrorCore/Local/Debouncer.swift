import Foundation

/// Fires a root's reconcile once it has been quiet for `quietPeriod`.
///
/// Roots are independent. A full-rescan request anywhere in a burst carries through to the
/// firing, because dropping it would leave changes the event stream lost unreconciled.
public actor Debouncer<C: Clock<Duration>> {
  private struct Pending {
    var generation = 0
    var fullRescan = false
    var task: Task<Void, Never>?
  }

  private let clock: C
  private let quietPeriod: Duration
  private let onFire: @Sendable (_ root: UUID, _ fullRescan: Bool) -> Void
  private var pending: [UUID: Pending] = [:]

  public init(
    clock: C, quietPeriod: Duration = .seconds(3),
    onFire: @escaping @Sendable (_ root: UUID, _ fullRescan: Bool) -> Void
  ) {
    self.clock = clock
    self.quietPeriod = quietPeriod
    self.onFire = onFire
  }

  public func record(root: UUID, fullRescan: Bool) {
    var entry = pending[root] ?? Pending()
    entry.task?.cancel()
    entry.generation += 1
    entry.fullRescan = entry.fullRescan || fullRescan
    // Computed here, not inside the task, so the deadline is fixed by when the event arrived
    // rather than by when the task happens to get scheduled.
    let deadline = clock.now.advanced(by: quietPeriod)
    let generation = entry.generation
    entry.task = Task { [clock] in
      do { try await clock.sleep(until: deadline, tolerance: nil) } catch { return }
      fire(root: root, generation: generation)
    }
    pending[root] = entry
  }

  public func cancelAll() {
    for entry in pending.values { entry.task?.cancel() }
    pending.removeAll()
  }

  private func fire(root: UUID, generation: Int) {
    // A newer event may have landed after this sleep finished but before we got the actor.
    guard let entry = pending[root], entry.generation == generation else { return }
    pending[root] = nil
    onFire(root, entry.fullRescan)
  }
}
