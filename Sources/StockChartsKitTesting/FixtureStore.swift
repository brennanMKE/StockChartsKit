import Foundation

/// The key used to match an incoming request to a recorded ``HTTPFixture``.
///
/// Matching is on the uppercased HTTP method plus the request path, with an
/// optional discriminator for endpoints that vary by query/body (e.g. a symbol
/// or a paging cursor). Hosts choose a stable, redaction-safe discriminator.
public struct FixtureKey: Hashable, Sendable {
  /// The uppercased HTTP method, e.g. `"GET"`.
  public let method: String
  /// The request path, e.g. `"/v1/accounts"`.
  public let path: String
  /// An optional discriminator distinguishing same-path requests.
  public let discriminator: String?

  /// Creates a fixture key, uppercasing `method`.
  public init(method: String, path: String, discriminator: String? = nil) {
    self.method = method.uppercased()
    self.path = path
    self.discriminator = discriminator
  }

  /// Derives a key from a `URLRequest`, ignoring any discriminator.
  public init(request: URLRequest) {
    self.method = (request.httpMethod ?? "GET").uppercased()
    self.path = request.url?.path ?? ""
    self.discriminator = nil
  }
}

/// Loads and holds ``HTTPFixture`` values for replay during a test.
///
/// ## Layout convention
/// Fixtures live alongside a provider's tests:
///
/// ```
/// Tests/<ProviderTests>/Fixtures/<name>.json
/// ```
///
/// Each `<name>.json` is a single recorded response (see ``HTTPFixture``). A
/// test registers each file against the request it should answer:
///
/// ```swift
/// let store = FixtureStore()
/// try store.register(
///   key: FixtureKey(method: "GET", path: "/v1/accounts"),
///   fixtureNamed: "accounts",
///   in: Bundle.module
/// )
/// ```
///
/// SwiftPM exposes a test target's `Fixtures/` directory through
/// `Bundle.module` when the target declares it as a resource. Tests may also
/// load fixtures from an explicit directory URL via ``register(key:fileURL:)``.
///
/// The store is a `final class` guarded by an internal lock so it is `Sendable`
/// and safe to read from ``ReplayURLProtocol`` on the URL loading thread.
public final class FixtureStore: @unchecked Sendable {
  private let lock = NSLock()
  private var fixtures: [FixtureKey: HTTPFixture] = [:]

  /// Creates an empty store.
  public init() {}

  /// Registers a fixture value directly under `key`.
  public func register(key: FixtureKey, fixture: HTTPFixture) {
    lock.lock()
    defer { lock.unlock() }
    fixtures[key] = fixture
  }

  /// Registers the fixture named `name` (without extension) from `bundle`.
  ///
  /// - Throws: ``ReplayError/fixtureNotFound(_:)`` if the resource is missing,
  ///   or a decoding error if the JSON is malformed.
  public func register(
    key: FixtureKey,
    fixtureNamed name: String,
    in bundle: Bundle,
    subdirectory: String = "Fixtures"
  ) throws {
    guard
      let url = bundle.url(
        forResource: name,
        withExtension: "json",
        subdirectory: subdirectory
      ) ?? bundle.url(forResource: name, withExtension: "json")
    else {
      throw ReplayError.fixtureNotFound(name)
    }
    try register(key: key, fileURL: url)
  }

  /// Registers a fixture decoded from the JSON file at `fileURL`.
  public func register(key: FixtureKey, fileURL: URL) throws {
    let data = try Data(contentsOf: fileURL)
    let fixture = try JSONDecoder().decode(HTTPFixture.self, from: data)
    register(key: key, fixture: fixture)
  }

  /// Returns the fixture matching `request`, trying the exact key first and
  /// then, if no discriminator was registered, a method+path-only key.
  func fixture(for request: URLRequest) -> HTTPFixture? {
    lock.lock()
    defer { lock.unlock() }
    let key = FixtureKey(request: request)
    return fixtures[key]
  }

  /// Whether any fixtures are registered.
  var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return fixtures.isEmpty
  }
}

/// Errors thrown by the HTTP-replay infrastructure.
public enum ReplayError: Error, Sendable, Equatable {
  /// No fixture file named `_` could be located in the bundle.
  case fixtureNotFound(String)
  /// A request reached the replay protocol with no matching fixture; the test
  /// would otherwise have hit the network.
  case noFixtureForRequest(method: String, path: String)
}
