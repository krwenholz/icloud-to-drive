import Foundation
import Testing

@testable import MirrorCore

private struct Firing: Equatable, Sendable {
  var root: UUID
  var fullRescan: Bool
}

@Suite struct DebouncerTests {
  private func makeDebouncer(_ clock: ManualClock) -> (Debouncer<ManualClock>, AsyncStream<Firing>)
  {
    let (stream, continuation) = AsyncStream.makeStream(of: Firing.self)
    let debouncer = Debouncer(clock: clock) { root, full in
      continuation.yield(Firing(root: root, fullRescan: full))
    }
    return (debouncer, stream)
  }

  @Test func firesAfterQuietPeriod() async {
    let clock = ManualClock()
    let (debouncer, stream) = makeDebouncer(clock)
    let root = UUID()
    await debouncer.record(root: root, fullRescan: false)
    await clock.waitForSleepers([.seconds(3)])

    clock.advance(by: .seconds(2))
    #expect(clock.sleeperDeadlines == [.seconds(3)])  // not fired yet
    clock.advance(by: .seconds(1))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == Firing(root: root, fullRescan: false))
  }

  @Test func newEventResetsTheWindow() async {
    let clock = ManualClock()
    let (debouncer, stream) = makeDebouncer(clock)
    let root = UUID()
    await debouncer.record(root: root, fullRescan: false)
    await clock.waitForSleepers([.seconds(3)])
    clock.advance(by: .seconds(2))
    await debouncer.record(root: root, fullRescan: false)
    await clock.waitForSleepers([.seconds(5)])

    clock.advance(by: .seconds(2))  // t=4: the original deadline has passed
    #expect(clock.sleeperDeadlines == [.seconds(5)])
    clock.advance(by: .seconds(1))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == Firing(root: root, fullRescan: false))
  }

  @Test func rootsDebounceIndependently() async {
    let clock = ManualClock()
    let (debouncer, stream) = makeDebouncer(clock)
    let a = UUID()
    let b = UUID()
    await debouncer.record(root: a, fullRescan: false)
    await clock.waitForSleepers([.seconds(3)])
    clock.advance(by: .seconds(2))
    await debouncer.record(root: b, fullRescan: false)
    await clock.waitForSleepers([.seconds(3), .seconds(5)])

    var iterator = stream.makeAsyncIterator()
    clock.advance(by: .seconds(1))
    #expect(await iterator.next() == Firing(root: a, fullRescan: false))
    #expect(clock.sleeperDeadlines == [.seconds(5)])
    clock.advance(by: .seconds(2))
    #expect(await iterator.next() == Firing(root: b, fullRescan: false))
  }

  @Test func fullRescanFlagIsPreserved() async {
    let clock = ManualClock()
    let (debouncer, stream) = makeDebouncer(clock)
    let root = UUID()
    await debouncer.record(root: root, fullRescan: true)
    await clock.waitForSleepers([.seconds(3)])
    await debouncer.record(root: root, fullRescan: false)
    await clock.waitForSleepers([.seconds(3)])
    clock.advance(by: .seconds(3))

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == Firing(root: root, fullRescan: true))
  }

  @Test func flagResetsAfterFiring() async {
    let clock = ManualClock()
    let (debouncer, stream) = makeDebouncer(clock)
    let root = UUID()
    var iterator = stream.makeAsyncIterator()
    await debouncer.record(root: root, fullRescan: true)
    await clock.waitForSleepers([.seconds(3)])
    clock.advance(by: .seconds(3))
    _ = await iterator.next()

    await debouncer.record(root: root, fullRescan: false)
    await clock.waitForSleepers([.seconds(6)])
    clock.advance(by: .seconds(3))
    #expect(await iterator.next() == Firing(root: root, fullRescan: false))
  }
}
