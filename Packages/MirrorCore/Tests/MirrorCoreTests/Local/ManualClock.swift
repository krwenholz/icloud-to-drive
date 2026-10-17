import Foundation
import os

/// A clock that only moves when a test calls `advance(by:)`, so debounce tests never sleep.
final class ManualClock: Clock, Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration
    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Waiter {
    var deadline: Instant
    var continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var waiters: [UUID: Waiter] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  var now: Instant { state.withLock { $0.now } }
  var minimumResolution: Duration { .zero }

  var sleeperDeadlines: [Duration] {
    state.withLock { $0.waiters.values.map(\.deadline.offset).sorted() }
  }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        enum Outcome { case resume, cancel, parked }
        let outcome = state.withLock { state -> Outcome in
          if Task.isCancelled { return .cancel }
          if deadline <= state.now { return .resume }
          state.waiters[id] = Waiter(deadline: deadline, continuation: continuation)
          return .parked
        }
        switch outcome {
        case .resume: continuation.resume()
        case .cancel: continuation.resume(throwing: CancellationError())
        case .parked: break
        }
      }
    } onCancel: {
      let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
      waiter?.continuation.resume(throwing: CancellationError())
    }
  }

  func advance(by duration: Duration) {
    let due = state.withLock { state -> [Waiter] in
      state.now = state.now.advanced(by: duration)
      let ids = state.waiters.filter { $0.value.deadline <= state.now }.map(\.key)
      return ids.compactMap { state.waiters.removeValue(forKey: $0) }
    }
    for waiter in due { waiter.continuation.resume() }
  }

  /// Yields (no wall-clock time) until exactly these deadlines are parked, so a test knows the
  /// debouncer's tasks have reached their sleeps before it advances.
  func waitForSleepers(_ deadlines: [Duration]) async {
    for _ in 0..<100_000 {
      if sleeperDeadlines == deadlines.sorted() { return }
      await Task.yield()
    }
  }
}
