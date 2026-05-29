import Foundation
import os

/// A `URLProtocol` that intercepts every request and replays a canned
/// ``HTTPFixture`` from a ``FixtureStore``, so provider tests run with no
/// network access.
///
/// ## Usage
/// Install the protocol on a configuration and obtain a session bound to a
/// store, then point the code under test at that session:
///
/// ```swift
/// let store = FixtureStore()
/// try store.register(
///   key: FixtureKey(method: "GET", path: "/v1/accounts"),
///   fixtureNamed: "accounts",
///   in: Bundle.module
/// )
/// let session = ReplayURLProtocol.makeSession(store: store)
/// defer { ReplayURLProtocol.deregister(session: session) }
/// let (data, response) = try await session.data(from: url)
/// ```
///
/// A request with no matching fixture fails with
/// ``ReplayError/noFixtureForRequest(method:path:)`` rather than escaping to the
/// network, so an un-recorded call is a loud test failure instead of a silent
/// live request.
public final class ReplayURLProtocol: URLProtocol {
  /// The request header carrying the session token that selects a store.
  static let tokenHeader = "X-StockChartsKit-Replay-Token"

  private static let logger = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "ReplayURLProtocol"
  )

  /// Token-keyed registry of fixture stores. Guarded by `registryLock`.
  nonisolated(unsafe) private static var registry: [String: FixtureStore] = [:]
  private static let registryLock = NSLock()

  // MARK: Session wiring

  /// Builds a `URLSessionConfiguration` with this protocol installed and bound
  /// to `store` via a fresh token header.
  public static func makeConfiguration(
    store: FixtureStore,
    base: URLSessionConfiguration = .ephemeral
  ) -> URLSessionConfiguration {
    let token = UUID().uuidString
    registryLock.lock()
    registry[token] = store
    registryLock.unlock()

    let configuration = base
    configuration.protocolClasses = [ReplayURLProtocol.self]
      + (configuration.protocolClasses ?? [])
    var headers = configuration.httpAdditionalHeaders ?? [:]
    headers[tokenHeader] = token
    configuration.httpAdditionalHeaders = headers
    return configuration
  }

  /// Builds a `URLSession` bound to `store` with this protocol installed.
  public static func makeSession(
    store: FixtureStore,
    base: URLSessionConfiguration = .ephemeral
  ) -> URLSession {
    URLSession(configuration: makeConfiguration(store: store, base: base))
  }

  /// Removes the store bound to `session`, freeing its registry entry.
  public static func deregister(session: URLSession) {
    guard
      let token = session.configuration.httpAdditionalHeaders?[tokenHeader] as? String
    else { return }
    deregister(token: token)
  }

  /// Removes the store bound to `token`.
  public static func deregister(token: String) {
    registryLock.lock()
    registry[token] = nil
    registryLock.unlock()
  }

  private static func store(for request: URLRequest) -> FixtureStore? {
    guard let token = request.value(forHTTPHeaderField: tokenHeader) else { return nil }
    registryLock.lock()
    defer { registryLock.unlock() }
    return registry[token]
  }

  // MARK: URLProtocol

  public override class func canInit(with request: URLRequest) -> Bool {
    // Only claim requests that carry our token, so unrelated sessions are
    // unaffected.
    request.value(forHTTPHeaderField: tokenHeader) != nil
  }

  public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  public override func startLoading() {
    guard let client else { return }
    let request = self.request

    guard let store = Self.store(for: request) else {
      let method = (request.httpMethod ?? "GET").uppercased()
      let path = request.url?.path ?? ""
      client.urlProtocol(
        self,
        didFailWithError: ReplayError.noFixtureForRequest(method: method, path: path)
      )
      return
    }

    guard let fixture = store.fixture(for: request) else {
      let method = (request.httpMethod ?? "GET").uppercased()
      let path = request.url?.path ?? ""
      Self.logger.error(
        "No fixture for \(method, privacy: .public) \(path, privacy: .public)"
      )
      client.urlProtocol(
        self,
        didFailWithError: ReplayError.noFixtureForRequest(method: method, path: path)
      )
      return
    }

    guard
      let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: fixture.statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: fixture.headers
      )
    else {
      client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !fixture.body.isEmpty {
      client.urlProtocol(self, didLoad: fixture.body)
    }
    client.urlProtocolDidFinishLoading(self)
  }

  public override func stopLoading() {
    // No teardown needed; responses are served synchronously in startLoading.
  }
}
