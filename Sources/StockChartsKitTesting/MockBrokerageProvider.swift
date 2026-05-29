import Foundation
import StockChartsKit

/// A fully programmable ``BrokerageProvider`` for use in tests.
///
/// Every response is configurable. ``id``, ``displayName``, ``capabilities``,
/// ``snapshotStore``, and ``marketData`` are set at construction (they are
/// `nonisolated` per the protocol). Each method's behaviour is driven by a
/// settable closure so a test can inject a canned value, a sequence of values,
/// or throwing behaviour:
///
/// ```swift
/// let mock = MockBrokerageProvider(id: ProviderID(rawValue: "test"))
/// await mock.setListAccounts { [account] }
/// await mock.setQuote { _ in throw BrokerageError.rateLimited(retryAfter: nil) }
/// ```
///
/// The provider is an `actor`, so its mutable closures are isolated and the
/// type is `Sendable`-clean under Swift 6 strict concurrency.
public actor MockBrokerageProvider: BrokerageProvider {
  // MARK: nonisolated identity

  public nonisolated let id: ProviderID
  public nonisolated let displayName: String
  public nonisolated let capabilities: Capabilities
  public nonisolated let snapshotStore: (any SnapshotStore)?
  public nonisolated let marketData: (any MarketDataProvider)?

  // MARK: Programmable behaviour

  /// Returns the current authentication status. Defaults to `.notAuthenticated`
  /// surfaced as `.error`.
  public var authenticationStatusHandler:
    @Sendable () async -> AuthenticationStatus

  /// Begins or resumes auth. Defaults to throwing ``BrokerageError/unsupported(method:)``.
  public var authenticateHandler: @Sendable () async throws -> AuthSession

  /// Revokes credentials. Defaults to a no-op.
  public var signOutHandler: @Sendable () async throws -> Void

  /// Lists accounts. Defaults to an empty list.
  public var listAccountsHandler: @Sendable () async throws -> [Account]

  /// Returns positions for an account. Defaults to an empty list.
  public var positionsHandler: @Sendable (AccountID) async throws -> [Position]

  /// Returns the balance for an account. Defaults to throwing
  /// ``BrokerageError/unsupported(method:)``.
  public var balanceHandler: @Sendable (AccountID) async throws -> Balance

  /// Returns the quote for a symbol. Defaults to throwing
  /// ``BrokerageError/unsupported(method:)``.
  public var quoteHandler: @Sendable (Symbol) async throws -> Quote

  /// Returns price history for a symbol. Defaults to throwing
  /// ``BrokerageError/unsupported(method:)``.
  public var priceHistoryHandler:
    @Sendable (Symbol, TimeRange) async throws -> PerformanceSeries

  /// Returns portfolio history for an account. Defaults to throwing
  /// ``BrokerageError/unsupported(method:)``.
  ///
  /// Issue 0010 introduces a default extension that reconstructs this from
  /// ``snapshotStore`` and ``marketData``; until then the mock simply surfaces
  /// whatever this override returns so tests can drive it directly.
  public var portfolioHistoryHandler:
    @Sendable (AccountID, TimeRange) async throws -> PerformanceSeries

  /// Creates a mock provider.
  ///
  /// - Parameters:
  ///   - id: The provider identifier.
  ///   - displayName: The human-readable name; defaults to `id.rawValue`.
  ///   - capabilities: The advertised capability set; defaults to empty.
  ///   - snapshotStore: An optional snapshot store dependency.
  ///   - marketData: An optional market-data dependency.
  public init(
    id: ProviderID,
    displayName: String? = nil,
    capabilities: Capabilities = [],
    snapshotStore: (any SnapshotStore)? = nil,
    marketData: (any MarketDataProvider)? = nil
  ) {
    self.id = id
    self.displayName = displayName ?? id.rawValue
    self.capabilities = capabilities
    self.snapshotStore = snapshotStore
    self.marketData = marketData
    self.authenticationStatusHandler = { .error(.notAuthenticated) }
    self.authenticateHandler = { throw BrokerageError.unsupported(method: "authenticate") }
    self.signOutHandler = {}
    self.listAccountsHandler = { [] }
    self.positionsHandler = { _ in [] }
    self.balanceHandler = { _ in throw BrokerageError.unsupported(method: "balance(for:)") }
    self.quoteHandler = { _ in throw BrokerageError.unsupported(method: "quote(for:)") }
    self.priceHistoryHandler = { _, _ in
      throw BrokerageError.unsupported(method: "priceHistory(symbol:range:)")
    }
    self.portfolioHistoryHandler = { _, _ in
      throw BrokerageError.unsupported(method: "portfolioHistory(accountID:range:)")
    }
  }

  // MARK: Configuration helpers

  /// Sets the authentication-status handler.
  public func setAuthenticationStatus(
    _ handler: @escaping @Sendable () async -> AuthenticationStatus
  ) {
    authenticationStatusHandler = handler
  }

  /// Sets the authenticate handler.
  public func setAuthenticate(
    _ handler: @escaping @Sendable () async throws -> AuthSession
  ) {
    authenticateHandler = handler
  }

  /// Sets the sign-out handler.
  public func setSignOut(_ handler: @escaping @Sendable () async throws -> Void) {
    signOutHandler = handler
  }

  /// Sets the list-accounts handler.
  public func setListAccounts(
    _ handler: @escaping @Sendable () async throws -> [Account]
  ) {
    listAccountsHandler = handler
  }

  /// Sets a canned list of accounts.
  public func setAccounts(_ accounts: [Account]) {
    listAccountsHandler = { accounts }
  }

  /// Sets the positions handler.
  public func setPositions(
    _ handler: @escaping @Sendable (AccountID) async throws -> [Position]
  ) {
    positionsHandler = handler
  }

  /// Sets the balance handler.
  public func setBalance(
    _ handler: @escaping @Sendable (AccountID) async throws -> Balance
  ) {
    balanceHandler = handler
  }

  /// Sets the quote handler.
  public func setQuote(
    _ handler: @escaping @Sendable (Symbol) async throws -> Quote
  ) {
    quoteHandler = handler
  }

  /// Sets the price-history handler.
  public func setPriceHistory(
    _ handler: @escaping @Sendable (Symbol, TimeRange) async throws -> PerformanceSeries
  ) {
    priceHistoryHandler = handler
  }

  /// Sets the portfolio-history handler.
  public func setPortfolioHistory(
    _ handler: @escaping @Sendable (AccountID, TimeRange) async throws -> PerformanceSeries
  ) {
    portfolioHistoryHandler = handler
  }

  // MARK: BrokerageProvider

  public func authenticationStatus() async -> AuthenticationStatus {
    await authenticationStatusHandler()
  }

  public func authenticate() async throws -> AuthSession {
    try await authenticateHandler()
  }

  public func signOut() async throws {
    try await signOutHandler()
  }

  public func listAccounts() async throws -> [Account] {
    try await listAccountsHandler()
  }

  public func positions(for accountID: AccountID) async throws -> [Position] {
    try await positionsHandler(accountID)
  }

  public func balance(for accountID: AccountID) async throws -> Balance {
    try await balanceHandler(accountID)
  }

  public func quote(for symbol: Symbol) async throws -> Quote {
    try await quoteHandler(symbol)
  }

  public func priceHistory(
    symbol: Symbol,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    try await priceHistoryHandler(symbol, range)
  }

  public func portfolioHistory(
    accountID: AccountID,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    try await portfolioHistoryHandler(accountID, range)
  }
}
