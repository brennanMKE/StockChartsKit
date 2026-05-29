import Foundation
import os

/// Signs an outgoing request just before it is sent.
///
/// Providers inject a signer to add Bearer tokens, OAuth 1.0a headers, or any
/// other per-request authorization. The ``HTTPClient`` applies the signer to
/// every attempt (including retries) at a single interception point, so signed
/// values such as timestamps and nonces are regenerated on each try.
///
/// The default signer used by ``HTTPClient`` is the identity transform
/// (``identity``), which leaves the request unchanged.
public struct RequestSigner: Sendable {
  /// The signing transform. Implementations must be pure with respect to
  /// shared mutable state and may be invoked on any executor.
  public let sign: @Sendable (URLRequest) async throws -> URLRequest

  /// Creates a signer from a closure.
  public init(_ sign: @escaping @Sendable (URLRequest) async throws -> URLRequest) {
    self.sign = sign
  }

  /// A signer that returns the request unchanged.
  public static let identity = RequestSigner { $0 }
}

/// Controls retry attempts and the wait between them.
///
/// The client retries HTTP `429` and `5xx` responses up to ``maxAttempts``
/// times total. Between attempts it waits the larger of the server-provided
/// `Retry-After` value and ``backoff(forAttempt:)``. Tests inject a policy with
/// a zero base so the suite never waits on a real clock.
public struct RetryPolicy: Sendable {
  /// The maximum number of attempts, including the first. Defaults to `3`.
  public let maxAttempts: Int

  /// The base delay used for exponential backoff. The wait for attempt `n`
  /// (1-based) is `base * 2^(n - 1)`.
  public let baseDelay: Duration

  /// Creates a retry policy.
  ///
  /// - Parameters:
  ///   - maxAttempts: The total number of attempts, including the first.
  ///   - baseDelay: The base backoff delay; `.zero` makes retries immediate.
  public init(maxAttempts: Int = 3, baseDelay: Duration = .seconds(1)) {
    self.maxAttempts = max(1, maxAttempts)
    self.baseDelay = baseDelay
  }

  /// The exponential backoff delay for a 1-based `attempt`.
  func backoff(forAttempt attempt: Int) -> Duration {
    guard attempt > 1 else { return .zero }
    let exponent = attempt - 1
    return baseDelay * (1 << exponent)
  }

  /// The default policy: 3 attempts with 1-second base backoff.
  public static let `default` = RetryPolicy()

  /// A policy with no delay between attempts, for fast deterministic tests.
  public static let immediate = RetryPolicy(baseDelay: .zero)
}

/// A small reusable HTTP client over `URLSession` that every provider wraps.
///
/// The client centralizes the cross-cutting concerns described in PRD §11:
///
/// - **Signing**: a single interception point (``RequestSigner``) applied to
///   every attempt, so providers add their authorization in one place.
/// - **Retry with backoff**: HTTP `429` and `5xx` are retried up to
///   ``RetryPolicy/maxAttempts`` times with exponential backoff. The
///   `Retry-After` header (both delta-seconds and HTTP-date forms) is honored,
///   and an exhausted `429` surfaces ``BrokerageError/rateLimited(retryAfter:)``.
/// - **Decoding**: responses decode through a `JSONDecoder` configured for
///   snake_case keys, ISO-8601 dates, and `Decimal` fields supplied as either
///   JSON numbers or numeric strings (see ``decode(_:from:)``).
/// - **Cancellation**: ``send(_:expecting:)`` checks for cancellation at entry
///   and relies on structured concurrency so the underlying `URLSession` work
///   is cancelled when the calling `Task` is.
///
/// No third-party HTTP client is used: requests go through
/// `URLSession.data(for:)` only.
///
/// ## Example
/// ```swift
/// let client = HTTPClient(
///   providerID: ProviderID(rawValue: "coinbase"),
///   signer: RequestSigner { request in
///     var signed = request
///     signed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
///     return signed
///   }
/// )
/// let accounts: AccountList = try await client.send(request, expecting: AccountList.self)
/// ```
public actor HTTPClient {
  private let session: URLSession
  private let providerID: ProviderID
  private let signer: RequestSigner
  private let retryPolicy: RetryPolicy
  private let sleep: @Sendable (Duration) async throws -> Void
  private let now: @Sendable () -> Date
  private let logger = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "networking"
  )

  /// A `JSONDecoder` configured per PRD §11.
  ///
  /// - `keyDecodingStrategy` is `.convertFromSnakeCase`.
  /// - Dates decode from ISO-8601.
  /// - `Decimal` values are tolerant of numeric strings: see
  ///   ``DecimalCodingWorkaround`` for how string-encoded decimals decode with
  ///   full precision.
  public nonisolated let decoder: JSONDecoder

  /// Creates an HTTP client.
  ///
  /// - Parameters:
  ///   - providerID: Labels ``BrokerageError/providerError(providerID:statusCode:message:)``
  ///     surfaced for non-retryable HTTP failures.
  ///   - session: The session to send through. Inject a session backed by a
  ///     replay `URLProtocol` in tests.
  ///   - signer: Applied to every attempt before sending. Defaults to the
  ///     identity transform.
  ///   - retryPolicy: Controls attempts and backoff. Defaults to
  ///     ``RetryPolicy/default``; pass ``RetryPolicy/immediate`` in tests.
  ///   - sleep: The wait primitive between attempts. Defaults to `Task.sleep`;
  ///     inject a no-op in tests to avoid real delays.
  ///   - now: Supplies the current date for `Retry-After` HTTP-date math.
  ///     Defaults to `Date.init`.
  public init(
    providerID: ProviderID,
    session: URLSession = .shared,
    signer: RequestSigner = .identity,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.providerID = providerID
    self.session = session
    self.signer = signer
    self.retryPolicy = retryPolicy
    self.sleep = sleep
    self.now = now
    self.decoder = Self.makeDecoder()
  }

  /// Builds the configured decoder. Exposed for reuse and testing.
  public static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  // MARK: Requests

  /// Sends `request` and decodes the response body as `T`.
  ///
  /// Retries `429`/`5xx` per the configured ``RetryPolicy``, then decodes the
  /// final successful body with the configured ``decoder``.
  ///
  /// - Throws: ``BrokerageError/network(underlying:)`` for transport failures,
  ///   ``BrokerageError/decodingFailed(underlying:)`` for decode failures,
  ///   ``BrokerageError/rateLimited(retryAfter:)`` for an exhausted `429`, and
  ///   ``BrokerageError/providerError(providerID:statusCode:message:)`` for
  ///   other non-retryable HTTP failures. Cancellation throws `CancellationError`.
  public func send<T: Decodable>(
    _ request: URLRequest,
    expecting type: T.Type = T.self
  ) async throws -> T {
    let data = try await send(request)
    return try decode(type, from: data)
  }

  /// Sends `request` and returns the raw response body of the final successful
  /// (non-retryable) attempt, applying the retry and signing rules.
  ///
  /// - Throws: As ``send(_:expecting:)``, except decoding errors (no decode is
  ///   performed here).
  public func send(_ request: URLRequest) async throws -> Data {
    try Task.checkCancellation()

    var lastRetryAfter: Date?
    let maxAttempts = retryPolicy.maxAttempts

    for attempt in 1...maxAttempts {
      try Task.checkCancellation()

      // Re-sign on every attempt so timestamps/nonces are fresh.
      let signed: URLRequest
      do {
        signed = try await signer.sign(request)
      } catch {
        throw BrokerageError.network(underlying: error)
      }

      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await session.data(for: signed)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as URLError where error.code == .cancelled {
        throw CancellationError()
      } catch {
        throw BrokerageError.network(underlying: error)
      }

      guard let http = response as? HTTPURLResponse else {
        throw BrokerageError.network(underlying: URLError(.badServerResponse))
      }

      let status = http.statusCode
      if (200..<300).contains(status) {
        return data
      }

      let isRetryable = status == 429 || (500..<600).contains(status)
      if isRetryable && attempt < maxAttempts {
        let retryAfter = Self.retryAfterDate(from: http, now: now())
        lastRetryAfter = retryAfter
        let wait = max(
          retryPolicy.backoff(forAttempt: attempt + 1),
          Self.duration(until: retryAfter, now: now())
        )
        logger.debug(
          "Retrying \(status, privacy: .public) attempt \(attempt, privacy: .public) of \(maxAttempts, privacy: .public)"
        )
        try await sleep(wait)
        continue
      }

      // Terminal failure: classify and throw.
      if status == 429 {
        let retryAfter = Self.retryAfterDate(from: http, now: now()) ?? lastRetryAfter
        throw BrokerageError.rateLimited(retryAfter: retryAfter)
      }
      let message = String(data: data, encoding: .utf8) ?? ""
      throw BrokerageError.providerError(
        providerID: providerID,
        statusCode: status,
        message: message
      )
    }

    // Unreachable: the loop returns or throws on every path, but the compiler
    // cannot prove the range is non-empty in all cases.
    throw BrokerageError.network(underlying: URLError(.unknown))
  }

  // MARK: Decoding

  /// Decodes `data` as `T` using the configured ``decoder``.
  ///
  /// - Throws: ``BrokerageError/decodingFailed(underlying:)`` on failure.
  public nonisolated func decode<T: Decodable>(
    _ type: T.Type = T.self,
    from data: Data
  ) throws -> T {
    do {
      return try decoder.decode(type, from: data)
    } catch {
      throw BrokerageError.decodingFailed(underlying: error)
    }
  }

  // MARK: Retry-After parsing

  /// Parses a `Retry-After` header into an absolute `Date`, supporting both the
  /// delta-seconds form (e.g. `120`) and the HTTP-date form (RFC 1123).
  static func retryAfterDate(from response: HTTPURLResponse, now: Date) -> Date? {
    guard
      let raw = response.value(forHTTPHeaderField: "Retry-After")?
        .trimmingCharacters(in: .whitespaces),
      !raw.isEmpty
    else { return nil }

    if let seconds = Double(raw) {
      return now.addingTimeInterval(seconds)
    }
    return httpDateFormatter.date(from: raw)
  }

  /// The delay from `now` until `date`, clamped at zero, as a `Duration`.
  static func duration(until date: Date?, now: Date) -> Duration {
    guard let date else { return .zero }
    let seconds = max(0, date.timeIntervalSince(now))
    return .seconds(seconds)
  }

  /// An RFC 1123 formatter for HTTP-date `Retry-After` values.
  private static let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
  }()
}
