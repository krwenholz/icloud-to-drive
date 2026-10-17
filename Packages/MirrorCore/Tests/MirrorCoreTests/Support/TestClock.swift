import Foundation

/// A settable wall clock, for code that takes `now: () -> Date`.
final class TestClock: @unchecked Sendable {
  // @unchecked: `date` is only touched under `lock`.
  private let lock = NSLock()
  private var date: Date

  init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { date = start }

  var now: Date { lock.withLock { date } }
  func advance(by seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
