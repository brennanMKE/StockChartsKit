import Foundation
import StockChartsKit
import os

/// A read-only ``BrokerageProvider`` that imports positions and balances from
/// CSV files in a directory.
///
/// `CSVImportProvider` is the simplest provider: it has no authentication and no
/// network access. It reads two CSV files from a directory — a positions file
/// and a balances file — parses them with a configurable ``ColumnMapping``, and
/// serves the parsed data through the standard provider methods. The directory
/// is watched for changes (via ``DirectoryWatcher``) and reparsed on each
/// mutation; the reparse logic is also exposed directly as ``reload()`` so it is
/// testable without depending on filesystem-event timing.
///
/// ## CSV schema
///
/// By convention the directory contains:
///
/// - **`positions.csv`** — one holding per row. The default mapping is the
///   headerless `symbol,quantity,price` form (e.g. `AMD,12,490.70`), with market
///   value derived as `quantity × price`. A header-based mapping
///   (``ColumnMapping/defaultPositionsHeader``) supports
///   `account,symbol,quantity,marketValue,averageCost,assetClass`.
/// - **`balances.csv`** — one account per row, header-based:
///   `account,total,cash,buyingPower`.
///
/// Both file names and both column mappings are configurable at construction.
///
/// `quote(for:)` and `priceHistory(symbol:range:)` are unsupported and throw
/// ``BrokerageError/unsupported(method:)``. `portfolioHistory(accountID:range:)`
/// is inherited from the protocol's default extension and works when a
/// ``snapshotStore`` and ``marketData`` are injected.
public actor CSVImportProvider: BrokerageProvider {
  private static let log = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "csv"
  )

  // MARK: nonisolated identity

  public nonisolated let id: ProviderID
  public nonisolated let displayName: String
  public nonisolated let capabilities: Capabilities = [.positions, .balances]
  public nonisolated let snapshotStore: (any SnapshotStore)?
  public nonisolated let marketData: (any MarketDataProvider)?

  // MARK: Configuration

  /// Default file name for the positions document.
  public static let defaultPositionsFileName = "positions.csv"
  /// Default file name for the balances document.
  public static let defaultBalancesFileName = "balances.csv"

  private let directory: URL
  private let positionsFileName: String
  private let balancesFileName: String
  private let positionsMapping: ColumnMapping
  private let balancesMapping: ColumnMapping
  private let parser: CSVPortfolioParser
  private let connectionID: ConnectionID
  private let now: @Sendable () -> Date

  // MARK: Parsed state

  private var positionsByAccount: [AccountID: [Position]] = [:]
  private var balancesByAccount: [AccountID: Balance] = [:]
  private var watcher: DirectoryWatcher?

  /// Creates a CSV import provider and performs an initial load.
  ///
  /// - Parameters:
  ///   - id: The provider identifier. Defaults to `ProviderID(rawValue: "csv")`.
  ///   - displayName: Human-readable name. Defaults to `"CSV Import"`.
  ///   - directory: The directory containing the CSV files.
  ///   - positionsFileName: The positions file name within `directory`.
  ///   - balancesFileName: The balances file name within `directory`.
  ///   - positionsMapping: How to map positions columns. Defaults to the
  ///     headerless `symbol,quantity,price` form.
  ///   - balancesMapping: How to map balances columns. Defaults to the
  ///     header-based `account,total,cash,buyingPower` form.
  ///   - currency: The base currency for parsed money. Defaults to USD.
  ///   - fallbackAccountID: The account used for positions rows without an
  ///     account column. Defaults to `AccountID(rawValue: "csv")`.
  ///   - watchDirectory: Whether to watch the directory and reload on change.
  ///     Defaults to `true`.
  ///   - snapshotStore: Optional snapshot store backing `portfolioHistory`.
  ///   - marketData: Optional market-data source backing `portfolioHistory`.
  ///   - now: A clock used to stamp parsed records. Injectable for tests.
  public init(
    id: ProviderID = ProviderID(rawValue: "csv"),
    displayName: String = "CSV Import",
    directory: URL,
    positionsFileName: String = CSVImportProvider.defaultPositionsFileName,
    balancesFileName: String = CSVImportProvider.defaultBalancesFileName,
    positionsMapping: ColumnMapping = .defaultPositionsPositional,
    balancesMapping: ColumnMapping = .defaultBalancesHeader,
    currency: CurrencyCode = .usd,
    fallbackAccountID: AccountID = AccountID(rawValue: "csv"),
    watchDirectory: Bool = true,
    snapshotStore: (any SnapshotStore)? = nil,
    marketData: (any MarketDataProvider)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) async {
    self.id = id
    self.displayName = displayName
    self.directory = directory
    self.positionsFileName = positionsFileName
    self.balancesFileName = balancesFileName
    self.positionsMapping = positionsMapping
    self.balancesMapping = balancesMapping
    self.connectionID = ConnectionID(rawValue: id.rawValue)
    self.parser = CSVPortfolioParser(
      currency: currency,
      fallbackAccountID: fallbackAccountID
    )
    self.snapshotStore = snapshotStore
    self.marketData = marketData
    self.now = now

    self.reload()

    if watchDirectory {
      self.startWatching()
    }
  }

  private func startWatching() {
    let watcher = DirectoryWatcher(url: directory) { [weak self] in
      guard let self else { return }
      Task { await self.reload() }
    }
    self.watcher = watcher
  }

  /// Stops watching the directory.
  ///
  /// Idempotent. After cancelling, data is served from the last successful load
  /// and only changes if ``reload()`` is called explicitly.
  public func stopWatching() {
    watcher?.cancel()
    watcher = nil
  }

  /// Re-reads and re-parses the positions and balances files.
  ///
  /// This is the single source of truth for refreshing the provider's state.
  /// The directory watcher simply calls this on every filesystem event, so the
  /// reload logic is fully covered by calling it directly in tests. Files that
  /// are missing or unreadable are treated as empty (logged at debug level);
  /// reload never throws.
  public func reload() {
    let asOf = now()

    let positionsURL = directory.appendingPathComponent(positionsFileName)
    if let text = Self.readText(at: positionsURL) {
      let positions = parser.positions(from: text, mapping: positionsMapping, asOf: asOf)
      positionsByAccount = Dictionary(grouping: positions, by: { $0.accountID })
    } else {
      positionsByAccount = [:]
    }

    let balancesURL = directory.appendingPathComponent(balancesFileName)
    if let text = Self.readText(at: balancesURL) {
      balancesByAccount = parser.balances(from: text, mapping: balancesMapping, asOf: asOf)
    } else {
      balancesByAccount = [:]
    }
  }

  private static func readText(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else {
      Self.log.debug("CSV file not readable: \(url.lastPathComponent, privacy: .public)")
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  // MARK: Authentication (none)

  public func authenticationStatus() async -> AuthenticationStatus {
    .connected(connectionID: connectionID)
  }

  public func authenticate() async throws -> AuthSession {
    NoopAuthSession()
  }

  public func signOut() async throws {
    // No credentials to revoke.
  }

  // MARK: Read

  public func listAccounts() async throws -> [Account] {
    let ids = Set(positionsByAccount.keys).union(balancesByAccount.keys)
    return ids
      .sorted { $0.rawValue < $1.rawValue }
      .map { accountID in
        Account(
          id: accountID,
          providerID: id,
          displayName: accountID.rawValue,
          kind: .brokerage,
          baseCurrency: parser.currency,
          connectionID: connectionID
        )
      }
  }

  public func positions(for accountID: AccountID) async throws -> [Position] {
    positionsByAccount[accountID] ?? []
  }

  public func balance(for accountID: AccountID) async throws -> Balance {
    guard let balance = balancesByAccount[accountID] else {
      throw BrokerageError.providerError(
        providerID: id,
        statusCode: nil,
        message: "No balance row for account \(accountID.rawValue)"
      )
    }
    return balance
  }

  public func quote(for symbol: Symbol) async throws -> Quote {
    throw BrokerageError.unsupported(method: "quote(for:)")
  }

  public func priceHistory(
    symbol: Symbol,
    range: TimeRange
  ) async throws -> PerformanceSeries {
    throw BrokerageError.unsupported(method: "priceHistory(symbol:range:)")
  }
}

/// A trivially-complete ``AuthSession`` for providers that need no
/// authentication.
private final class NoopAuthSession: AuthSession {
  func complete(callbackURL: URL) async throws {}
  func complete(pinCode: String) async throws {}
  func cancel() async {}
}
