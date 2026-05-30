import Foundation
import StockChartsKit
import os

/// A read-only ``BrokerageProvider`` for a single brokerage connected through
/// SnapTrade (one SnapTrade `Connection` / `brokerage_authorization`).
///
/// SnapTrade is an aggregator: a user may connect several brokerages, and the
/// package exposes **one provider per connected brokerage** rather than one
/// global SnapTrade provider. Each provider is scoped to a single brokerage
/// authorization and only ever reports the accounts under it.
///
/// ## Identity
/// The ``id`` is namespaced from the brokerage name:
/// `ProviderID("snaptrade.robinhood")`, `"snaptrade.fidelity"`, etc. (see
/// ``ProviderID/snapTrade(brokerageName:)``). ``displayName`` is the human
/// brokerage name.
///
/// ## Capabilities
/// `[.positions, .balances]`. SnapTrade exposes no per-symbol price history, so
/// ``quote(for:)`` and ``priceHistory(symbol:range:)`` throw
/// ``BrokerageError/unsupported(method:)``; the host falls back to a
/// ``MarketDataProvider``.
///
/// ## Signing
/// Every request carries `clientId`, `userId`, `userSecret`, and a `timestamp`
/// as query parameters plus a `Signature` header (see ``SnapTradeSigner``). The
/// `userSecret` is read from the injected ``TokenStore`` at send time and is
/// never logged.
public actor SnapTradeConnectionProvider: BrokerageProvider {
  // MARK: nonisolated identity

  public nonisolated let id: ProviderID
  public nonisolated let displayName: String
  public nonisolated let capabilities: Capabilities = [.positions, .balances]
  public nonisolated let snapshotStore: (any SnapshotStore)?
  public nonisolated let marketData: (any MarketDataProvider)?

  // MARK: Configuration

  /// The SnapTrade brokerage-authorization id this provider is scoped to. Only
  /// accounts under this authorization are reported.
  private let authorizationID: String
  private let connectionID: ConnectionID
  private let tokenStore: any TokenStore
  private let api: SnapTradeAPI
  private let client: HTTPClient
  private let now: @Sendable () -> Date

  private let logger = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "snaptrade"
  )

  /// Creates a connection provider.
  ///
  /// - Parameters:
  ///   - brokerageName: The human brokerage name; drives ``displayName`` and the
  ///     namespaced ``id``.
  ///   - authorizationID: The SnapTrade `brokerage_authorization` id this
  ///     provider is scoped to.
  ///   - clientID: The developer-app `clientId`.
  ///   - consumerKey: The developer-app `consumerKey`, used as the HMAC key.
  ///     Never logged.
  ///   - tokenStore: Where the per-user `userId`/`userSecret` are read from.
  ///   - connectionID: Groups this connection's accounts. Defaults to the
  ///     authorization id.
  ///   - session: The `URLSession` for all requests. Inject a replay-backed
  ///     session in tests; defaults to `.shared`.
  ///   - retryPolicy: HTTP retry policy. Defaults to ``RetryPolicy/default``.
  ///   - sleep: Wait primitive between retries. Defaults to `Task.sleep`.
  ///   - snapshotStore: Optional snapshot store backing `portfolioHistory`.
  ///   - marketData: Optional market-data source backing `portfolioHistory`.
  ///   - now: Supplies the current date. Defaults to `Date.init`.
  ///   - timestamp: Supplies the request `timestamp`. Defaults to `now` in
  ///     epoch seconds; tests inject a fixed value.
  public init(
    brokerageName: String,
    authorizationID: String,
    clientID: String,
    consumerKey: String,
    tokenStore: any TokenStore,
    connectionID: ConnectionID? = nil,
    session: URLSession = .shared,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    snapshotStore: (any SnapshotStore)? = nil,
    marketData: (any MarketDataProvider)? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    timestamp: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
  ) {
    self.id = ProviderID.snapTrade(brokerageName: brokerageName)
    self.displayName = brokerageName
    self.authorizationID = authorizationID
    self.connectionID = connectionID ?? ConnectionID(rawValue: authorizationID)
    self.tokenStore = tokenStore
    self.snapshotStore = snapshotStore
    self.marketData = marketData
    self.now = now
    self.api = SnapTradeAPI(clientID: clientID, consumerKey: consumerKey, timestamp: timestamp)
    self.client = HTTPClient(
      providerID: ProviderID.snapTrade(brokerageName: brokerageName),
      session: session,
      retryPolicy: retryPolicy,
      sleep: sleep,
      now: now
    )
  }

  // MARK: Authentication

  public func authenticationStatus() async -> AuthenticationStatus {
    do {
      _ = try await tokenStore.loadUserCredentials()
      return .connected(connectionID: connectionID)
    } catch BrokerageError.notAuthenticated {
      return .error(.notAuthenticated)
    } catch {
      return .error(Self.brokerageError(error))
    }
  }

  /// SnapTrade registration is driven by ``SnapTradeProviders`` (the hosted
  /// portal flow), not by an individual connection provider, so calling
  /// `authenticate()` on an already-discovered connection is unsupported.
  public func authenticate() async throws -> AuthSession {
    throw BrokerageError.unsupported(method: "authenticate")
  }

  /// Clears the stored per-user credentials, signing out of every SnapTrade
  /// connection (the credentials are shared across connections).
  public func signOut() async throws {
    try await tokenStore.delete(snapTradeUserCredentialsKey)
  }

  // MARK: Read

  public func listAccounts() async throws -> [Account] {
    let credentials = try await loadCredentials()
    let accounts = try await client.send(
      try api.signedRequest(method: "GET", path: "/accounts", credentials: credentials),
      expecting: [SnapTradeAccount].self
    )
    return accounts
      .filter { $0.brokerageAuthorization?.id == authorizationID }
      .map { wire in
        Account(
          id: AccountID(rawValue: wire.id),
          providerID: id,
          displayName: wire.name ?? wire.number ?? displayName,
          kind: .brokerage,
          baseCurrency: CurrencyCode(rawValue: wire.currency?.code ?? "USD"),
          connectionID: connectionID
        )
      }
  }

  public func positions(for accountID: AccountID) async throws -> [Position] {
    let credentials = try await loadCredentials()
    let wirePositions = try await client.send(
      try api.signedRequest(
        method: "GET",
        path: "/accounts/\(accountID.rawValue)/positions",
        credentials: credentials
      ),
      expecting: [SnapTradePosition].self
    )
    let asOf = now()
    return wirePositions.compactMap { wire -> Position? in
      guard
        let detail = wire.symbol?.symbol,
        let raw = detail.symbol
      else { return nil }
      let quantity = wire.units?.wrappedValue ?? 0
      let currency = CurrencyCode(rawValue: detail.currency?.code ?? "USD")
      let price = wire.price?.wrappedValue ?? 0
      return Position(
        accountID: accountID,
        symbol: Symbol(rawValue: raw),
        assetClass: Self.assetClass(for: detail.type?.code),
        quantity: quantity,
        averageCost: wire.averagePurchasePrice.map { Money($0.wrappedValue, currency) },
        marketValue: Money(quantity * price, currency),
        unrealizedPL: wire.openPnl.map { Money($0.wrappedValue, currency) },
        asOf: asOf
      )
    }
  }

  public func balance(for accountID: AccountID) async throws -> Balance {
    let credentials = try await loadCredentials()
    let balances = try await client.send(
      try api.signedRequest(
        method: "GET",
        path: "/accounts/\(accountID.rawValue)/balances",
        credentials: credentials
      ),
      expecting: [SnapTradeBalance].self
    )
    guard let first = balances.first else {
      throw BrokerageError.providerError(
        providerID: id,
        statusCode: nil,
        message: "No balance for account \(accountID.rawValue)"
      )
    }
    let currency = CurrencyCode(rawValue: first.currency?.code ?? "USD")
    let cash = first.cash?.wrappedValue ?? 0
    return Balance(
      accountID: accountID,
      total: Money(cash, currency),
      cash: Money(cash, currency),
      buyingPower: first.buyingPower.map { Money($0.wrappedValue, currency) },
      asOf: now()
    )
  }

  public func quote(for symbol: Symbol) async throws -> Quote {
    throw BrokerageError.unsupported(method: "quote")
  }

  public func priceHistory(
    symbol: Symbol,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    throw BrokerageError.unsupported(method: "priceHistory")
  }

  // MARK: Helpers

  private func loadCredentials() async throws -> SnapTradeUserCredentials {
    try await tokenStore.loadUserCredentials()
  }

  /// Maps a SnapTrade instrument-type code to a package ``AssetClass``.
  static func assetClass(for code: String?) -> AssetClass {
    switch code?.lowercased() {
    case "cs", "ad", "common stock", "equity": return .equity
    case "et", "etf": return .etf
    case "mf", "mutual fund": return .mutualFund
    case "oef", "cef", "bond": return .bond
    case "crypto", "cur": return .crypto
    case "opt", "option": return .option
    default: return .other
    }
  }

  /// Maps an arbitrary error to a ``BrokerageError`` without leaking detail.
  private static func brokerageError(_ error: Error) -> BrokerageError {
    if let brokerage = error as? BrokerageError { return brokerage }
    return BrokerageError.network(underlying: error)
  }
}
