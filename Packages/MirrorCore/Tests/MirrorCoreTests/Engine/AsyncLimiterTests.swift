import Testing

@testable import MirrorCore

struct AsyncLimiterTests {
  @Test func queuesBeyondTheLimitAndHandsOffSlots() async {
    let limiter = AsyncLimiter(limit: 2)
    await limiter.acquire()
    await limiter.acquire()

    let third = Task { await limiter.acquire() }
    while await limiter.waitingCount == 0 { await Task.yield() }
    #expect(await limiter.waitingCount == 1)

    await limiter.release()
    await third.value
    #expect(await limiter.waitingCount == 0)

    // Two slots are held again (the original second plus the third); a fourth must wait.
    let fourth = Task { await limiter.acquire() }
    while await limiter.waitingCount == 0 { await Task.yield() }
    await limiter.release()
    await fourth.value
  }
}
