import Foundation

/// A read-only portfolio data source that every brokerage backend conforms to.
///
/// A provider is an `actor` so internal state (tokens, refresh timers, in-flight
/// requests) is automatically isolated. ``id``, ``displayName``, and
/// ``capabilities`` are `nonisolated` and pure so a host can enumerate providers
/// without hopping actors. The injected ``snapshotStore`` and ``marketData``
/// dependencies back the default `portfolioHistory(accountID:range:)`
/// reconstruction; both may be `nil` when a provider has
/// ``Capabilities/nativePortfolioHistory``.
public protocol BrokerageProvider: Actor {
  /// Stable identifier, e.g. `"etrade"`, `"snaptrade.robinhood"`, `"coinbase"`.
  nonisolated var id: ProviderID { get }

  /// Human-readable name for UI, e.g. `"E*Trade"`, `"Robinhood"`.
  nonisolated var displayName: String { get }

  /// What this provider can and cannot do. Hosts inspect this before asking for
  /// capabilities the provider lacks.
  nonisolated var capabilities: Capabilities { get }

  /// The snapshot store backing the default `portfolioHistory` reconstruction.
  nonisolated var snapshotStore: (any SnapshotStore)? { get }

  /// The market-data source backing the default `portfolioHistory`
  /// reconstruction and any non-native price history.
  nonisolated var marketData: (any MarketDataProvider)? { get }

  // MARK: Authentication

  /// Returns `.connected` if a valid session exists, otherwise an
  /// ``AuthChallenge`` the host must resolve, or an error.
  func authenticationStatus() async -> AuthenticationStatus

  /// Begins or resumes auth. The returned ``AuthSession`` is owned by the
  /// provider; the host drives it through its callbacks.
  func authenticate() async throws -> AuthSession

  /// Revokes and clears any stored credentials.
  func signOut() async throws

  // MARK: Read

  /// Lists the accounts visible to this provider's connection.
  func listAccounts() async throws -> [Account]

  /// Returns the positions held in `accountID`.
  func positions(for accountID: AccountID) async throws -> [Position]

  /// Returns the balance for `accountID`.
  func balance(for accountID: AccountID) async throws -> Balance

  /// Returns the current quote for `symbol`.
  ///
  /// Providers that do not supply quotes (e.g. CSV import) throw
  /// ``BrokerageError/unsupported(method:)``.
  func quote(for symbol: Symbol) async throws -> Quote

  /// Returns per-symbol price history over `range`.
  ///
  /// Providers without native history throw ``BrokerageError/unsupported(method:)``;
  /// the host falls back to a ``MarketDataProvider``.
  func priceHistory(symbol: Symbol, range: TimeRange) async throws -> PerformanceSeries

  /// Returns per-account portfolio value over `range`.
  ///
  /// Most providers do not expose this natively; the default extension
  /// reconstructs it from the injected ``snapshotStore`` and ``marketData``.
  /// Throws ``BrokerageError/unsupported(method:)`` if neither native history
  /// nor those dependencies exist.
  func portfolioHistory(accountID: AccountID, range: TimeRange) async throws -> PerformanceSeries
}

/// The set of features a ``BrokerageProvider`` supports.
public struct Capabilities: OptionSet, Sendable, Codable {
  /// The bitmask backing this option set.
  public let rawValue: Int

  /// Creates a capability set from a raw bitmask.
  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// Reports per-account positions.
  public static let positions = Capabilities(rawValue: 1 << 0)
  /// Reports per-account balances.
  public static let balances = Capabilities(rawValue: 1 << 1)
  /// Reports current quotes.
  public static let quotes = Capabilities(rawValue: 1 << 2)
  /// Supplies per-symbol price history natively.
  public static let nativePriceHistory = Capabilities(rawValue: 1 << 3)
  /// Supplies per-account portfolio-value history natively.
  public static let nativePortfolioHistory = Capabilities(rawValue: 1 << 4)
  /// Holds crypto assets.
  public static let crypto = Capabilities(rawValue: 1 << 5)
  /// Supports real-time streaming (future).
  public static let realtimeStreaming = Capabilities(rawValue: 1 << 6)
}

/// The result of inspecting a provider's authentication state.
public enum AuthenticationStatus: Sendable {
  /// A valid session exists for the given connection.
  case connected(connectionID: ConnectionID)
  /// The host must resolve the given challenge to authenticate.
  case requiresChallenge(AuthChallenge)
  /// Determining status failed with the given error.
  case error(BrokerageError)
}
