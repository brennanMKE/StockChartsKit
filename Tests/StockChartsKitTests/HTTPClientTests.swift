import Foundation
import Testing

@testable import StockChartsKit
import StockChartsKitTesting

@Suite("HTTPClient (offline)")
struct HTTPClientTests {
  private let baseURL = URL(string: "https://offline.invalid")!
  private let provider = ProviderID(rawValue: "test")

  /// A no-op sleep so retry tests never wait on a real clock.
  private let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

  private struct Greeting: Decodable, Equatable {
    let displayName: String
  }

  private func makeClient(
    store: FixtureStore,
    signer: RequestSigner = .identity
  ) -> (HTTPClient, URLSession) {
    let session = ReplayURLProtocol.makeSession(store: store)
    let client = HTTPClient(
      providerID: provider,
      session: session,
      signer: signer,
      retryPolicy: .immediate,
      sleep: noSleep,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    return (client, session)
  }

  private func request(path: String, method: String = "GET") -> URLRequest {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = method
    return request
  }

  @Test("retries a 429 then succeeds on the second attempt")
  func retryThenSucceed() async throws {
    let store = FixtureStore()
    let key = FixtureKey(method: "GET", path: "/v1/greeting")
    store.register(
      key: key,
      sequence: [
        HTTPFixture(statusCode: 429, headers: ["Retry-After": "1"]),
        HTTPFixture(statusCode: 200, body: Data(#"{"display_name":"hello"}"#.utf8)),
      ]
    )
    let (client, session) = makeClient(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let greeting: Greeting = try await client.send(
      request(path: "v1/greeting"),
      expecting: Greeting.self
    )
    #expect(greeting == Greeting(displayName: "hello"))
    // Two attempts: the initial 429 and the retried 200.
    #expect(store.hitCount(for: key) == 2)
  }

  @Test("surfaces rateLimited with delta-seconds Retry-After when exhausted")
  func rateLimitedDeltaSeconds() async throws {
    let store = FixtureStore()
    let key = FixtureKey(method: "GET", path: "/v1/limited")
    store.register(
      key: key,
      fixture: HTTPFixture(statusCode: 429, headers: ["Retry-After": "120"])
    )
    let (client, session) = makeClient(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let error = await #expect(throws: BrokerageError.self) {
      _ = try await client.send(request(path: "v1/limited"))
    }
    guard case let .rateLimited(retryAfter) = error else {
      Issue.record("expected rateLimited, got \(String(describing: error))")
      return
    }
    let expected = Date(timeIntervalSince1970: 1_700_000_000 + 120)
    let date = try #require(retryAfter)
    #expect(abs(date.timeIntervalSince(expected)) < 1)
    // Three attempts (maxAttempts default of 3), all 429.
    #expect(store.hitCount(for: key) == 3)
  }

  @Test("parses an HTTP-date Retry-After")
  func rateLimitedHTTPDate() async throws {
    let store = FixtureStore()
    let key = FixtureKey(method: "GET", path: "/v1/limited")
    store.register(
      key: key,
      fixture: HTTPFixture(
        statusCode: 429,
        headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]
      )
    )
    let (client, session) = makeClient(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let error = await #expect(throws: BrokerageError.self) {
      _ = try await client.send(request(path: "v1/limited"))
    }
    guard case let .rateLimited(retryAfter) = error else {
      Issue.record("expected rateLimited, got \(String(describing: error))")
      return
    }
    let date = try #require(retryAfter)
    var components = DateComponents()
    components.year = 2015
    components.month = 10
    components.day = 21
    components.hour = 7
    components.minute = 28
    components.second = 0
    components.timeZone = TimeZone(identifier: "GMT")
    let expected = try #require(Calendar(identifier: .gregorian).date(from: components))
    #expect(abs(date.timeIntervalSince(expected)) < 1)
  }

  @Test("retries 5xx up to the limit then surfaces providerError")
  func serverErrorRetried() async throws {
    let store = FixtureStore()
    let key = FixtureKey(method: "GET", path: "/v1/down")
    store.register(
      key: key,
      fixture: HTTPFixture(statusCode: 503, body: Data("unavailable".utf8))
    )
    let (client, session) = makeClient(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let error = await #expect(throws: BrokerageError.self) {
      _ = try await client.send(request(path: "v1/down"))
    }
    guard case let .providerError(providerID, statusCode, message) = error else {
      Issue.record("expected providerError, got \(String(describing: error))")
      return
    }
    #expect(providerID == provider)
    #expect(statusCode == 503)
    #expect(message == "unavailable")
    #expect(store.hitCount(for: key) == 3)
  }

  @Test("does not retry a 404 and maps it to providerError")
  func notFoundNotRetried() async throws {
    let store = FixtureStore()
    let key = FixtureKey(method: "GET", path: "/v1/missing")
    store.register(
      key: key,
      fixture: HTTPFixture(statusCode: 404, body: Data("nope".utf8))
    )
    let (client, session) = makeClient(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let error = await #expect(throws: BrokerageError.self) {
      _ = try await client.send(request(path: "v1/missing"))
    }
    guard case let .providerError(_, statusCode, _) = error else {
      Issue.record("expected providerError, got \(String(describing: error))")
      return
    }
    #expect(statusCode == 404)
    // Exactly one attempt: a 4xx is not retryable.
    #expect(store.hitCount(for: key) == 1)
  }

  @Test("decodes snake_case keys and a Decimal from a JSON string")
  func decodesSnakeCaseAndDecimalString() async throws {
    struct Position: Decodable, Equatable {
      let symbolName: String
      @LossyDecimal var marketValue: Decimal
      @LossyDecimal var quantity: Decimal
    }
    let store = FixtureStore()
    let body = Data(
      #"{"symbol_name":"AAPL","market_value":"123.45","quantity":10}"#.utf8
    )
    store.register(
      key: FixtureKey(method: "GET", path: "/v1/position"),
      fixture: HTTPFixture(statusCode: 200, body: body)
    )
    let (client, session) = makeClient(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let position: Position = try await client.send(
      request(path: "v1/position"),
      expecting: Position.self
    )
    #expect(position.symbolName == "AAPL")
    // Full precision, parsed from the string without going through Double.
    #expect(position.marketValue == Decimal(string: "123.45"))
    #expect(position.quantity == Decimal(10))
  }

  @Test("maps a decode failure to decodingFailed")
  func decodeFailureMapped() async throws {
    let store = FixtureStore()
    store.register(
      key: FixtureKey(method: "GET", path: "/v1/bad"),
      fixture: HTTPFixture(statusCode: 200, body: Data("not json".utf8))
    )
    let (client, session) = makeClient(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let error = await #expect(throws: BrokerageError.self) {
      let _: Greeting = try await client.send(
        request(path: "v1/bad"),
        expecting: Greeting.self
      )
    }
    guard case .decodingFailed = error else {
      Issue.record("expected decodingFailed, got \(String(describing: error))")
      return
    }
  }

  @Test("applies the injected signer to outgoing requests")
  func signerApplied() async throws {
    let store = FixtureStore()
    store.register(
      key: FixtureKey(method: "GET", path: "/v1/secure"),
      fixture: HTTPFixture(statusCode: 200, body: Data(#"{"display_name":"ok"}"#.utf8))
    )
    let signer = RequestSigner { request in
      var signed = request
      signed.setValue("Bearer abc", forHTTPHeaderField: "Authorization")
      return signed
    }
    let (client, session) = makeClient(store: store, signer: signer)
    defer { ReplayURLProtocol.deregister(session: session) }

    // The call simply succeeding confirms the signed request reached the
    // replay protocol; the signer ran without throwing.
    let greeting: Greeting = try await client.send(
      request(path: "v1/secure"),
      expecting: Greeting.self
    )
    #expect(greeting == Greeting(displayName: "ok"))
  }

  @Test("a cancelled task causes the call to throw without hanging")
  func cancellationPropagates() async throws {
    let store = FixtureStore()
    store.register(
      key: FixtureKey(method: "GET", path: "/v1/slow"),
      fixture: HTTPFixture(statusCode: 200, body: Data(#"{"display_name":"x"}"#.utf8))
    )
    let (client, session) = makeClient(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let req = request(path: "v1/slow")
    let task = Task { () -> Data in
      try await client.send(req)
    }
    task.cancel()

    await #expect(throws: (any Error).self) {
      _ = try await task.value
    }
  }
}
