import Foundation

/// When and how long to wait before retrying a Drive request.
public struct RetryPolicy: Sendable {
  public var maxAttempts: Int
  public var baseDelay: Duration
  public var maxDelay: Duration
  /// Returns a value in `0..<1`; injectable so tests get exact delays.
  public var random: @Sendable () -> Double
  public var sleep: @Sendable (Duration) async throws -> Void

  public init(
    maxAttempts: Int = 5,
    baseDelay: Duration = .seconds(1),
    maxDelay: Duration = .seconds(32),
    random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.maxAttempts = maxAttempts
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.random = random
    self.sleep = sleep
  }

  /// Exponential backoff plus up to one second of jitter, capped, unless Drive said how long.
  func delay(beforeRetry attempt: Int, retryAfter: Duration?) -> Duration {
    if let retryAfter { return min(retryAfter, maxDelay) }
    let exponential = baseDelay * (1 << min(attempt - 1, 16))
    return min(exponential + .milliseconds(Int(random() * 1000)), maxDelay)
  }

  static func isRetryable(status: Int, reason: String?) -> Bool {
    switch status {
    case 429, 500...599: true
    case 403: reason == "rateLimitExceeded" || reason == "userRateLimitExceeded"
    default: false
    }
  }

  static func isRetryable(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
      .cannotFindHost, .dnsLookupFailed:
      true
    default: false
    }
  }

  /// Parses `Retry-After` as either delta-seconds or an HTTP date.
  static func parseRetryAfter(_ value: String?, now: Date = Date()) -> Duration? {
    guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
      return nil
    }
    if let seconds = Int(value) { return .seconds(max(seconds, 0)) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: value) else { return nil }
    return .seconds(max(date.timeIntervalSince(now), 0))
  }
}
