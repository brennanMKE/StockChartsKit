import Foundation
import StockChartsKit
import os

/// Entry point for the SnapTrade integration: end-user registration, the hosted
/// connection portal, and per-connection provider discovery.
///
/// SnapTrade is a brokerage aggregator covering Robinhood, Fidelity (retail and
/// NetBenefits), Acorns, Vanguard, Wealthfront, Webull, Public, Wells Fargo, and
/// dozens more. The package exposes **one provider per connected brokerage**, so
/// ``discover(configuration:tokenStore:snapshotStore:marketData:session:)``
/// returns an array of ``SnapTradeConnectionProvider``, one per connection.
///
/// ## Registration flow
/// 1. ``registerUser(userId:configuration:tokenStore:session:)`` registers the
///    end user and persists the returned `userId`/`userSecret`.
/// 2. ``loginURL(configuration:tokenStore:session:)`` generates a hosted-portal
///    URL, surfaced as ``AuthChallenge/hostedPortal(url:)``, that the host opens
///    in a web view so the user can connect their brokerages.
/// 3. After the user connects, ``discover(...)`` enumerates the connections.
///
/// All requests are signed with the SnapTrade `Signature` header. The
/// `consumerKey` (HMAC key) and the per-user `userSecret` are never logged.
public enum SnapTradeProviders {
  private static let logger = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "snaptrade"
  )

  // MARK: Registration

  /// Registers an end user with SnapTrade and persists the returned
  /// `userId`/`userSecret` via `tokenStore`.
  ///
  /// Calls `POST /api/v1/snapTrade/registerUser`, authenticated with only the
  /// developer-app `clientId`/`consumerKey` (no per-user credentials yet).
  ///
  /// - Parameters:
  ///   - userId: The host-chosen end-user identifier to register.
  ///   - configuration: Must carry `"clientId"` and `"consumerKey"`.
  ///   - tokenStore: Where the issued credentials are persisted. Never logged.
  ///   - session: The `URLSession` for the request. Inject a replay-backed
  ///     session in tests; defaults to `.shared`.
  ///   - retryPolicy: HTTP retry policy. Defaults to ``RetryPolicy/default``.
  ///   - sleep: Wait primitive between retries. Defaults to `Task.sleep`.
  ///   - timestamp: Supplies the request `timestamp`. Defaults to now.
  /// - Returns: The persisted ``SnapTradeUserCredentials``.
  @discardableResult
  public static func registerUser(
    userId: String,
    configuration: Configuration,
    tokenStore: any TokenStore,
    session: URLSession = .shared,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    timestamp: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
  ) async throws -> SnapTradeUserCredentials {
    let api = try makeAPI(configuration: configuration, timestamp: timestamp)
    let client = makeClient(session: session, retryPolicy: retryPolicy, sleep: sleep)

    let body = try JSONSerialization.data(withJSONObject: ["userId": userId], options: [.sortedKeys])
    let request = try api.signedRequest(
      method: "POST",
      path: "/snapTrade/registerUser",
      credentials: nil,
      body: body
    )
    let response = try await client.send(request, expecting: SnapTradeRegisterUserResponse.self)
    let credentials = SnapTradeUserCredentials(
      userId: response.userId,
      userSecret: response.userSecret
    )
    try await tokenStore.storeUserCredentials(credentials)
    logger.debug("Registered SnapTrade user and stored credentials")
    return credentials
  }

  // MARK: Login (hosted portal)

  /// Generates a hosted connection-portal URL for the registered user.
  ///
  /// Calls `POST /api/v1/snapTrade/login` using the stored per-user credentials.
  ///
  /// - Returns: The portal URL to present in a web view.
  /// - Throws: ``BrokerageError/notAuthenticated`` if no credentials are stored.
  public static func loginURL(
    configuration: Configuration,
    tokenStore: any TokenStore,
    session: URLSession = .shared,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    timestamp: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
  ) async throws -> URL {
    let api = try makeAPI(configuration: configuration, timestamp: timestamp)
    let client = makeClient(session: session, retryPolicy: retryPolicy, sleep: sleep)
    let credentials = try await tokenStore.loadUserCredentials()

    let request = try api.signedRequest(
      method: "POST",
      path: "/snapTrade/login",
      credentials: credentials,
      body: Data("{}".utf8)
    )
    let response = try await client.send(request, expecting: SnapTradeLoginResponse.self)
    guard let url = URL(string: response.redirectURI) else {
      throw BrokerageError.providerError(
        providerID: ProviderID(rawValue: "snaptrade"),
        statusCode: nil,
        message: "SnapTrade login returned an unparseable redirect URI"
      )
    }
    return url
  }

  /// Generates the hosted-portal login URL and wraps it as an ``AuthChallenge``.
  public static func loginChallenge(
    configuration: Configuration,
    tokenStore: any TokenStore,
    session: URLSession = .shared,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    timestamp: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
  ) async throws -> AuthChallenge {
    let url = try await loginURL(
      configuration: configuration,
      tokenStore: tokenStore,
      session: session,
      retryPolicy: retryPolicy,
      sleep: sleep,
      timestamp: timestamp
    )
    return .hostedPortal(url: url)
  }

  // MARK: Discovery

  /// Enumerates the user's connected brokerages and returns one
  /// ``SnapTradeConnectionProvider`` per connection.
  ///
  /// Fetches `GET /accounts` with the stored per-user credentials, groups the
  /// accounts by their `brokerage_authorization`, and builds one provider per
  /// distinct authorization with a namespaced ``ProviderID`` derived from the
  /// brokerage name.
  ///
  /// Per the PRD's Fidelity/NetBenefits note, this makes no assumption about
  /// which accounts a single login can see — it enumerates whatever SnapTrade
  /// returns.
  ///
  /// - Parameters:
  ///   - configuration: Must carry `"clientId"` and `"consumerKey"`.
  ///   - tokenStore: Source of the per-user credentials.
  ///   - snapshotStore: Optional snapshot store injected into each provider.
  ///   - marketData: Optional market-data source injected into each provider.
  ///   - session: The `URLSession` for the discovery request and shared with the
  ///     returned providers. Defaults to `.shared`.
  ///   - retryPolicy: HTTP retry policy. Defaults to ``RetryPolicy/default``.
  ///   - sleep: Wait primitive between retries. Defaults to `Task.sleep`.
  ///   - now: Supplies the current date for the providers. Defaults to `Date.init`.
  ///   - timestamp: Supplies the request `timestamp`. Defaults to now.
  /// - Returns: One provider per connected brokerage, ordered by display name.
  /// - Throws: ``BrokerageError/notAuthenticated`` if no credentials are stored.
  public static func discover(
    configuration: Configuration,
    tokenStore: any TokenStore,
    snapshotStore: (any SnapshotStore)? = nil,
    marketData: (any MarketDataProvider)? = nil,
    session: URLSession = .shared,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = Date.init,
    timestamp: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
  ) async throws -> [any BrokerageProvider] {
    let clientID = try configuration.requiredSecret("clientId")
    let consumerKey = try configuration.requiredSecret("consumerKey")
    let api = SnapTradeAPI(clientID: clientID, consumerKey: consumerKey, timestamp: timestamp)
    let client = makeClient(session: session, retryPolicy: retryPolicy, sleep: sleep)
    let credentials = try await tokenStore.loadUserCredentials()

    let accounts = try await client.send(
      try api.signedRequest(method: "GET", path: "/accounts", credentials: credentials),
      expecting: [SnapTradeAccount].self
    )

    // Group accounts by their brokerage authorization, preserving the first
    // brokerage name seen for each. Authorizations with no name fall back to the
    // authorization id so they still surface as a distinct provider.
    var order: [String] = []
    var names: [String: String] = [:]
    for account in accounts {
      guard let authorization = account.brokerageAuthorization else { continue }
      if names[authorization.id] == nil {
        order.append(authorization.id)
      }
      // Prefer a real brokerage name over a previously stored fallback.
      let name = authorization.brokerageName ?? names[authorization.id] ?? authorization.id
      names[authorization.id] = name
    }

    return order.map { authorizationID in
      let brokerageName = names[authorizationID] ?? authorizationID
      return SnapTradeConnectionProvider(
        brokerageName: brokerageName,
        authorizationID: authorizationID,
        clientID: clientID,
        consumerKey: consumerKey,
        tokenStore: tokenStore,
        session: session,
        retryPolicy: retryPolicy,
        sleep: sleep,
        snapshotStore: snapshotStore,
        marketData: marketData,
        now: now,
        timestamp: timestamp
      )
    }
  }

  // MARK: Internals

  private static func makeAPI(
    configuration: Configuration,
    timestamp: @escaping @Sendable () -> Int
  ) throws -> SnapTradeAPI {
    let clientID = try configuration.requiredSecret("clientId")
    let consumerKey = try configuration.requiredSecret("consumerKey")
    return SnapTradeAPI(clientID: clientID, consumerKey: consumerKey, timestamp: timestamp)
  }

  private static func makeClient(
    session: URLSession,
    retryPolicy: RetryPolicy,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) -> HTTPClient {
    HTTPClient(
      providerID: ProviderID(rawValue: "snaptrade"),
      session: session,
      retryPolicy: retryPolicy,
      sleep: sleep
    )
  }
}
