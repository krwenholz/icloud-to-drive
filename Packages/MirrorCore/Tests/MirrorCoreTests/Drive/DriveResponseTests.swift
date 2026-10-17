import Foundation
import Testing

@testable import MirrorCore

/// Retry, refresh, and failure behavior of `GoogleDriveClient`.
struct DriveResponseTests {
  let stub = HTTPStub()
  let tokens = StaticTokenProvider()
  let sleeps = SleepRecorder()
  let client: GoogleDriveClient

  static let ok = HTTPStub.Response.json(
    200,
    #"{"id":"f1","name":"garden","mimeType":"application/vnd.google-apps.document","parents":["p"],"appProperties":{"h":"x"},"modifiedTime":"2026-10-16T12:00:00.123Z"}"#
  )

  init() {
    let sleeps = sleeps
    client = GoogleDriveClient(
      tokens: tokens, session: stub.session,
      retry: RetryPolicy(random: { 0.5 }, sleep: { await sleeps.record($0) }))
  }

  private func trash() async throws { try await client.trashFile(id: "f1") }

  private static func error(_ status: Int, reason: String, headers: [String: String] = [:])
    -> HTTPStub.Response
  {
    .json(
      status, #"{"error":{"code":\#(status),"message":"nope","errors":[{"reason":"\#(reason)"}]}}"#,
      headers: headers)
  }

  @Test func decodesFileOnSuccess() async throws {
    stub.enqueue(Self.ok)
    let file = try await client.getFile(id: "f1")
    #expect(file.name == "garden")
    #expect(file.parents == ["p"])
    #expect(file.appProperties == ["h": "x"])
    #expect(file.modifiedTime == GoogleDriveClient.parseDate("2026-10-16T12:00:00.123Z"))
    #expect(file.modifiedTime != nil)
  }

  @Test func refreshesTokenOnceAfter401() async throws {
    stub.enqueue(Self.error(401, reason: "authError"), Self.ok)
    try await trash()
    #expect(
      stub.requests.map { $0.header("Authorization") } == ["Bearer token-1", "Bearer token-2"])
    #expect(await tokens.invalidations == 1)
    #expect(await sleeps.durations.isEmpty)
  }

  @Test func repeated401Fails() async throws {
    stub.enqueue(Self.error(401, reason: "authError"), Self.error(401, reason: "authError"))
    await #expect(throws: DriveError.http(status: 401, reason: "authError", message: "nope")) {
      try await trash()
    }
    #expect(stub.requests.count == 2)
  }

  @Test func honorsRetryAfterOn429() async throws {
    stub.enqueue(
      Self.error(429, reason: "rateLimitExceeded", headers: ["Retry-After": "7"]), Self.ok)
    try await trash()
    #expect(stub.requests.count == 2)
    #expect(await sleeps.durations == [.seconds(7)])
  }

  @Test func retriesUserRateLimit403() async throws {
    stub.enqueue(Self.error(403, reason: "userRateLimitExceeded"), Self.ok)
    try await trash()
    #expect(await sleeps.durations == [.milliseconds(1500)])
  }

  @Test func doesNotRetryPermission403() async throws {
    stub.enqueue(Self.error(403, reason: "insufficientPermissions"))
    await #expect(throws: DriveError.self) { try await trash() }
    #expect(stub.requests.count == 1)
  }

  @Test func repeated5xxBacksOffThenGivesUp() async throws {
    stub.respond { _ in Self.error(503, reason: "backendError") }
    await #expect(throws: DriveError.http(status: 503, reason: "backendError", message: "nope")) {
      try await trash()
    }
    #expect(stub.requests.count == 5)
    // 1s, 2s, 4s, 8s of exponential backoff, each plus 0.5s of (injected) jitter.
    #expect(
      await sleeps.durations == [
        .milliseconds(1500), .milliseconds(2500), .milliseconds(4500), .milliseconds(8500),
      ])
  }

  @Test func recoversAfterTransient5xx() async throws {
    stub.enqueue(Self.error(500, reason: "backendError"), Self.error(502, reason: "x"), Self.ok)
    try await trash()
    #expect(stub.requests.count == 3)
  }

  @Test func nonRetryable400FailsImmediately() async throws {
    stub.enqueue(Self.error(400, reason: "badRequest"))
    await #expect(throws: DriveError.http(status: 400, reason: "badRequest", message: "nope")) {
      try await trash()
    }
    #expect(stub.requests.count == 1)
    #expect(await sleeps.durations.isEmpty)
  }

  @Test func listFollowsPageTokens() async throws {
    stub.enqueue(
      .json(200, #"{"files":[{"id":"a"}],"nextPageToken":"p2"}"#),
      .json(200, #"{"files":[{"id":"b"},{"id":"c"}]}"#))
    let files = try await client.listFiles(appProperty: "r", value: "root")
    #expect(files.map(\.id) == ["a", "b", "c"])
    #expect(stub.requests.map { $0.query["pageToken"] } == [nil, "p2"])
  }

  @Test func emailIsNilWhenAboutIsForbidden() async throws {
    stub.enqueue(Self.error(403, reason: "insufficientPermissions"))
    #expect(try await client.userEmail() == nil)
  }

  @Test func parsesRetryAfterDates() {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    #expect(RetryPolicy.parseRetryAfter("Sun, 09 Sep 2001 01:46:50 GMT", now: now) == .seconds(10))
    #expect(RetryPolicy.parseRetryAfter("soon", now: now) == nil)
    #expect(RetryPolicy.parseRetryAfter(nil) == nil)
  }

  @Test func capsBackoffAtMaxDelay() {
    let policy = RetryPolicy(random: { 0.999 })
    #expect(policy.delay(beforeRetry: 10, retryAfter: nil) == .seconds(32))
    #expect(policy.delay(beforeRetry: 1, retryAfter: .seconds(600)) == .seconds(32))
  }
}

actor SleepRecorder {
  private(set) var durations: [Duration] = []
  func record(_ duration: Duration) { durations.append(duration) }
}
