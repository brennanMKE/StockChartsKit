# StockChartsKit — Swift Package Specification

> Package/module names use the `StockChartsKit` prefix to match the repo.
> Domain type names that describe brokerages (`BrokerageProvider`,
> `BrokerageError`, `Capabilities`, …) keep the "Brokerage" naming — the kit
> is about stock charts; the things it reads from are brokerages.

A Swift package that exposes a unified protocol for reading portfolio data from
multiple brokerages, with concrete implementations for E*Trade, Coinbase,
SnapTrade (which itself covers Robinhood, Fidelity / NetBenefits, Acorns, and
others), Schwab, and a CSV-import fallback. Consumed by a macOS app that
renders charts and a portfolio total.

Target audience for this spec: Claude Code, executing in a clean repo.

---

## 1. Goals and non-goals

### Goals

- One Swift-native protocol, `BrokerageProvider`, that all backends conform to.
- Read-only portfolio data: accounts, positions, balances, current quotes,
  per-symbol price history, per-account portfolio-value history.
- First-class time ranges matching the Robinhood-style chart selector:
  `1D`, `1W`, `1M`, `3M`, `YTD`, `1Y`, `5Y`, `MAX`.
- Async/await throughout. Swift 6 strict concurrency. No callbacks, no Combine.
- Concrete implementations for: E*Trade (official OAuth 1.0a), Coinbase
  (official API), SnapTrade (covering Robinhood, Fidelity / NetBenefits,
  Acorns, Vanguard, Wealthfront, etc.), Schwab (official OAuth 2.0), and a
  CSV-import provider for everything else.
- Local snapshot store so providers that only return current state can still
  produce historical portfolio-value series.
- Sendable, value-typed public API. No reference types in the public surface
  unless required (e.g., the provider itself can be an actor).

### Non-goals

- Trading. Read-only for v1. The protocol should leave room to add write
  capabilities later but should not include them now.
- UI. No SwiftUI views in this package. The macOS app consumes the package
  and renders charts with Swift Charts.
- Tax-lot accounting, cost-basis adjustments, wash-sale tracking. Out of scope.
- Cross-brokerage transaction de-duplication.

### Platform requirements

- Swift 6.1 or later.
- `swift-tools-version:6.1`.
- Platforms: `.macOS(.v14)`. **macOS only for v1.** iOS is a future addition
  — keep the public protocol surface iOS-friendly, but auth
  (`ASWebAuthenticationSession`), Keychain access groups, and snapshot
  scheduling will all need iOS-specific rework before that target is added.
- Strict concurrency enabled (`SwiftSettings.enableUpcomingFeature("StrictConcurrency")`).

---

## 2. Package layout

```
StockChartsKit/
├── Package.swift
├── README.md
├── Sources/
│   ├── StockChartsKit/                # Core protocol + types
│   │   ├── Protocols/
│   │   │   ├── BrokerageProvider.swift
│   │   │   ├── MarketDataProvider.swift
│   │   │   └── SnapshotStore.swift
│   │   ├── Models/
│   │   │   ├── Account.swift
│   │   │   ├── Position.swift
│   │   │   ├── Balance.swift
│   │   │   ├── Quote.swift
│   │   │   ├── Money.swift
│   │   │   ├── PerformanceSeries.swift
│   │   │   └── TimeRange.swift
│   │   ├── Auth/
│   │   │   ├── AuthChallenge.swift
│   │   │   ├── AuthSession.swift
│   │   │   └── KeychainStore.swift
│   │   ├── Errors/
│   │   │   └── BrokerageError.swift
│   │   ├── Aggregation/
│   │   │   └── PortfolioAggregator.swift
│   │   └── Snapshot/
│   │       └── SQLiteSnapshotStore.swift
│   ├── StockChartsKitETrade/          # E*Trade impl
│   ├── StockChartsKitCoinbase/        # Coinbase impl
│   ├── StockChartsKitSnapTrade/       # SnapTrade impl (Robinhood, Fidelity, Acorns, ...)
│   ├── StockChartsKitSchwab/          # Schwab impl
│   ├── StockChartsKitCSV/             # CSV import impl
│   └── StockChartsKitMarketData/      # Default market data (Tiingo + Yahoo fallback)
└── Tests/
    ├── StockChartsKitTests/
    ├── StockChartsKitETradeTests/
    ├── StockChartsKitCoinbaseTests/
    ├── StockChartsKitSnapTradeTests/
    ├── StockChartsKitSchwabTests/
    └── StockChartsKitCSVTests/
```

`Package.swift` declares one product per provider so the host app can pick which
ones to link. The core `StockChartsKit` target has no provider-specific code and
no third-party dependencies beyond `swift-crypto` and the standard library.

---

## 3. Core data model

All types are `public`, `Sendable`, value types, and `Codable` where it makes
sense. Use `Foundation.Decimal` for money, never `Double`.

### 3.1 Money

```swift
public struct Money: Hashable, Sendable, Codable {
    public let amount: Decimal
    public let currency: CurrencyCode      // ISO 4217, e.g. "USD"

    public init(_ amount: Decimal, _ currency: CurrencyCode = .usd)
    public static func usd(_ amount: Decimal) -> Money
    public static let zero: Money = .usd(0)

    public static func + (lhs: Money, rhs: Money) throws -> Money   // throws on currency mismatch
    public static func - (lhs: Money, rhs: Money) throws -> Money
    public static func * (lhs: Money, rhs: Decimal) -> Money
}

public struct CurrencyCode: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String            // "USD", "EUR", "BTC", "ETH", ...
    public init(rawValue: String) { self.rawValue = rawValue.uppercased() }
    public static let usd = CurrencyCode(rawValue: "USD")
}
```

Currency-mismatched arithmetic throws `BrokerageError.currencyMismatch`. The
aggregator (section 8) does FX conversion when summing across currencies.

**Rounding.** `Money` stores full `Decimal` precision and never rounds
internally — `*` and FX products keep all significant digits. Rounding to a
currency's minor units (2 for USD, up to 8+ for crypto) is a *presentation*
concern handled by the host at display time, not by the model. Equality and
hashing are on the exact stored `Decimal`.

### 3.2 TimeRange

Matches the Robinhood chart selector exactly.

```swift
public enum TimeRange: String, CaseIterable, Sendable, Codable {
    case oneDay   = "1D"
    case oneWeek  = "1W"
    case oneMonth = "1M"
    case threeMonths = "3M"
    case yearToDate  = "YTD"
    case oneYear  = "1Y"
    case fiveYears = "5Y"
    case max      = "MAX"

    /// (start, end) date interval anchored at `now`. For `max`, returns
    /// `(.distantPast, now)`; the provider clamps to its available history.
    public func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval

    /// Recommended sample granularity (used as a hint to providers that
    /// support it, e.g. 1-minute candles for 1D, daily for ≥1M).
    public var granularity: Granularity
}

public enum Granularity: Sendable, Codable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case oneHour
    case oneDay
    case oneWeek
}
```

### 3.3 Account

```swift
public struct Account: Identifiable, Hashable, Sendable, Codable {
    public let id: AccountID              // stable, provider-scoped identifier
    public let providerID: ProviderID     // which provider owns this account
    public let displayName: String        // e.g. "E*Trade Brokerage 1234"
    public let kind: AccountKind          // brokerage, ira, roth, 401k, crypto, hsa, ...
    public let baseCurrency: CurrencyCode
    public let connectionID: ConnectionID?  // groups accounts that share one auth
}

public struct AccountID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
}

public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String           // "etrade", "coinbase", "snaptrade.robinhood", ...
}

public struct ConnectionID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
}

public enum AccountKind: String, Sendable, Codable {
    case brokerage, margin, ira, rothIRA, traditional401k, roth401k,
         hsa, fhsa, esa, custodial, crypto, retirement, savings, other
}
```

### 3.4 Position

```swift
public struct Position: Hashable, Sendable, Codable {
    public let accountID: AccountID
    public let symbol: Symbol             // canonical ticker (e.g. "AMD")
    public let assetClass: AssetClass     // equity, etf, crypto, mutualFund, option, bond, cash
    public let quantity: Decimal          // can be fractional
    public let averageCost: Money?        // nil if unknown
    public let marketValue: Money         // quantity * lastPrice
    public let unrealizedPL: Money?
    public let asOf: Date                 // when this snapshot was taken
}

public struct Symbol: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String           // "AMD", "BTC-USD", "VFFSX", ...
}

public enum AssetClass: String, Sendable, Codable {
    case equity, etf, mutualFund, option, bond, crypto, cash, other
}
```

### 3.5 Balance

```swift
public struct Balance: Hashable, Sendable, Codable {
    public let accountID: AccountID
    public let total: Money               // total account value
    public let cash: Money                // settled cash
    public let buyingPower: Money?        // optional, brokerage-specific
    public let asOf: Date
}
```

### 3.6 Quote

```swift
public struct Quote: Hashable, Sendable, Codable {
    public let symbol: Symbol
    public let last: Money
    public let previousClose: Money?
    public let asOf: Date
}
```

### 3.7 PerformanceSeries

The data type backing every chart. The screenshot you provided is a
`PerformanceSeries` for symbol `AMD`, range `3M`, rendered as a line.

```swift
public struct PerformanceSeries: Hashable, Sendable, Codable {
    public let subject: Subject           // symbol or account
    public let range: TimeRange
    public let points: [Point]
    public let granularity: Granularity

    public struct Point: Hashable, Sendable, Codable {
        public let timestamp: Date
        public let value: Money
    }

    public enum Subject: Hashable, Sendable, Codable {
        case symbol(Symbol)
        case account(AccountID)
        case portfolio(providerID: ProviderID?)   // nil = aggregate across all
    }

    /// Convenience: start value, end value, absolute change, percent change.
    /// Matches the "$+290.85 (+145.35%) Past 3 months" header in the chart.
    /// `nil` when `points` is empty.
    public var summary: Summary? { ... }

    public struct Summary: Sendable {
        public let start: Money
        public let end: Money
        public let absoluteChange: Money
        public let percentChange: Decimal?     // 1.4535 == 145.35%; nil if start == 0
    }
    // When `start.amount == 0` (new account, position opened mid-range),
    // `percentChange` is `nil` — callers show only the absolute change.
    // When `points` is empty, `summary` is nil.
}
```

---

## 4. The core protocol

```swift
public protocol BrokerageProvider: Actor {
    /// Stable identifier, e.g. "etrade", "snaptrade.robinhood", "coinbase".
    nonisolated var id: ProviderID { get }

    /// Human-readable name for UI: "E*Trade", "Robinhood", "Fidelity NetBenefits".
    nonisolated var displayName: String { get }

    /// What this provider can and cannot do. Inspected by the host before
    /// asking for capabilities the provider does not have.
    nonisolated var capabilities: Capabilities { get }

    /// Dependencies for the default `portfolioHistory` reconstruction (§7).
    /// Providers receive these at init from the host and store them. When a
    /// provider has `.nativePortfolioHistory`, both may be `nil`.
    nonisolated var snapshotStore: (any SnapshotStore)? { get }
    nonisolated var marketData: (any MarketDataProvider)? { get }

    // MARK: Authentication

    /// Returns `.connected` if a valid session exists, otherwise returns
    /// an `AuthChallenge` the host must resolve (typically by presenting a
    /// web view or opening a URL).
    func authenticationStatus() async -> AuthenticationStatus

    /// Begin or resume auth. The returned `AuthSession` is owned by the
    /// provider; the host drives it through its callbacks.
    func authenticate() async throws -> AuthSession

    /// Revoke and clear any stored credentials.
    func signOut() async throws

    // MARK: Read

    func listAccounts() async throws -> [Account]
    func positions(for accountID: AccountID) async throws -> [Position]
    func balance(for accountID: AccountID) async throws -> Balance

    /// Current quote for a symbol. Providers that do not supply quotes
    /// (e.g. CSV import) throw `.unsupported`.
    func quote(for symbol: Symbol) async throws -> Quote

    /// Per-symbol price history. The screenshot is this method's output.
    /// Providers without native history throw `.unsupported`; the host
    /// falls back to `MarketDataProvider`.
    func priceHistory(symbol: Symbol, range: TimeRange) async throws -> PerformanceSeries

    /// Per-account portfolio value over time. Most providers do not expose
    /// this natively. The default extension implementation reconstructs it
    /// from the provider's injected `snapshotStore` + `marketData` (§7).
    /// Throws `.unsupported` if neither native history nor those deps exist.
    func portfolioHistory(accountID: AccountID, range: TimeRange) async throws -> PerformanceSeries
}

public struct Capabilities: OptionSet, Sendable, Codable {
    public let rawValue: Int
    public static let positions               = Capabilities(rawValue: 1 << 0)
    public static let balances                = Capabilities(rawValue: 1 << 1)
    public static let quotes                  = Capabilities(rawValue: 1 << 2)
    public static let nativePriceHistory      = Capabilities(rawValue: 1 << 3)
    public static let nativePortfolioHistory  = Capabilities(rawValue: 1 << 4)
    public static let crypto                  = Capabilities(rawValue: 1 << 5)
    public static let realtimeStreaming       = Capabilities(rawValue: 1 << 6)  // future
}

public enum AuthenticationStatus: Sendable {
    case connected(connectionID: ConnectionID)
    case requiresChallenge(AuthChallenge)
    case error(BrokerageError)
}
```

The provider is an `actor` so internal state (tokens, refresh timers,
in-flight requests) is automatically isolated. `id`, `displayName`, and
`capabilities` are `nonisolated` and pure so the host can list providers
without hopping actors.

---

## 5. Authentication

Each provider drives its own auth dance. The host hands the package an
`AuthChallenge` resolver and the package calls back when it needs the user
to do something (open a URL, paste a code, etc.).

```swift
public enum AuthChallenge: Sendable {
    /// Open this URL in a browser, capture the redirect back to `callbackScheme`,
    /// then call `complete(callbackURL:)`.
    case oauthRedirect(authorizationURL: URL, callbackScheme: String)

    /// User pastes a verifier code (E*Trade OAuth 1.0a flow).
    case pinCode(authorizationURL: URL)

    /// User must complete MFA in their broker's app.
    case mfaPushNotification(prompt: String)

    /// SnapTrade's hosted connection portal.
    case hostedPortal(url: URL)
}

public protocol AuthSession: AnyObject, Sendable {
    func complete(callbackURL: URL) async throws
    func complete(pinCode: String) async throws
    func cancel() async
}
```

Persisted credentials live in the macOS Keychain. The package vends a
`KeychainStore` actor that wraps `SecItemAdd` / `SecItemCopyMatching`. Per
provider, store one item keyed by `\(providerID).\(connectionID)` with the
service set to the app's bundle identifier. Never log token values.

### 5.1 Secrets and configuration

**No secret is ever hardcoded in source — not even at debug level, not in
fixtures, not in defaults.** This is a hard rule (see §18).

Two kinds of secret exist and both are supplied at runtime by the host app:

1. **Developer-app credentials** — the per-provider keys you register with each
   brokerage's developer portal (E*Trade `consumerKey`/`consumerSecret`,
   Coinbase client ID, Schwab client ID/secret, SnapTrade `clientId`/`consumerKey`).
2. **Per-user tokens** — OAuth access/refresh tokens, SnapTrade `userId`/`userSecret`,
   obtained during the auth dance.

The package never reads these from environment or disk on its own. Each provider
takes a `Configuration` value at init carrying only the developer-app
credentials it needs; per-user tokens are read/written through `KeychainStore`.

```swift
public struct Configuration: Sendable {
    public let secrets: [String: String]   // opaque, provider-defined keys
    public init(secrets: [String: String])
}
```

**Host integration (this app).** The macOS app is a local, single-machine app
with no backend. During **onboarding** the user adds each service: the app
presents the auth flow, collects the developer-app credentials and the
resulting per-user tokens, and writes them to the **platform Keychain**. After
onboarding, connected services are listed and managed in **Settings** (view
status, re-authenticate, sign out, remove). The package supports this by
vending `KeychainStore` for the app to read/write through; the app passes the
retrieved developer-app credentials into each provider's `Configuration` at
launch and never bakes them into the binary.

> **Distribution caveat.** Because there is no backend, developer-app secrets
> live only in the user's Keychain on their own machine. This is safe for a
> personal, non-distributed app. If this app is ever distributed, the
> developer-app secrets would need to move behind a backend proxy — revisit
> before shipping. Documented in `README.md` (§15).

Coinbase uses **OAuth 2.0 with PKCE and no client secret** — only a client ID
is stored.

---

## 6. Market data

Many brokerages do not provide per-symbol charting history. The package
defines a separate protocol so the host can supply (or default to) a
market data source.

```swift
public protocol MarketDataProvider: Sendable {
    func quote(symbol: Symbol) async throws -> Quote
    func priceHistory(symbol: Symbol, range: TimeRange) async throws -> PerformanceSeries
}
```

Default implementation in `StockChartsKitMarketData`:

- Primary: **Tiingo** (`https://api.tiingo.com`). Free tier requires an
  API token; daily prices for 500 symbols / month. Best for daily charts.
- Fallback: **Yahoo Finance chart endpoint** (`https://query1.finance.yahoo.com/v8/finance/chart/{symbol}`).
  Undocumented, no auth, frequently used. Treat as best-effort and document
  the legal grey area in `README.md`.
- The default `MarketDataProvider` is a composite that tries Tiingo first
  and falls back to Yahoo on any failure.

The host can replace it with anything implementing the protocol (Polygon,
Alpaca data, IEX Cloud, etc.).

**Quota and caching.** Tiingo's free tier is ~500 symbols/month, so the tiered
provider caches fetched daily bars locally (reuse the snapshot SQLite DB or a
sibling table) and serves cache-first for daily granularity, only hitting the
network for missing/stale ranges. Intraday (`1D`) is fetched live. This keeps a
multi-symbol portfolio comfortably under quota.

---

## 7. The snapshot store

E*Trade, Robinhood (via SnapTrade), and Fidelity all return *current* state.
To draw a per-account chart, the package periodically snapshots positions
and balances locally and reconstructs the historical series.

```swift
public protocol SnapshotStore: Actor {
    func recordSnapshot(_ snapshot: PortfolioSnapshot) async throws
    func snapshots(accountID: AccountID, in interval: DateInterval) async throws -> [PortfolioSnapshot]
    func snapshots(providerID: ProviderID?, in interval: DateInterval) async throws -> [PortfolioSnapshot]
    func prune(olderThan date: Date) async throws
}

public struct PortfolioSnapshot: Hashable, Sendable, Codable {
    public let accountID: AccountID
    public let timestamp: Date
    public let totalValue: Money
    public let positions: [Position]
}
```

Default implementation: `SQLiteSnapshotStore`, backed by [GRDB.swift]. Schema:

```sql
CREATE TABLE snapshot (
    account_id   TEXT NOT NULL,
    timestamp    REAL NOT NULL,         -- Unix epoch
    total_value  TEXT NOT NULL,         -- Decimal serialized as string
    currency     TEXT NOT NULL,
    PRIMARY KEY (account_id, timestamp)
);
CREATE INDEX snapshot_ts ON snapshot(timestamp);

-- Schema versioning: use GRDB's DatabaseMigrator (or PRAGMA user_version).
-- v1 is the schema below. Every future change ships as a new, ordered
-- migration; never mutate an existing migration. SQLiteSnapshotStore runs
-- pending migrations on init so an existing user's DB upgrades in place.

CREATE TABLE snapshot_position (
    account_id   TEXT NOT NULL,
    timestamp    REAL NOT NULL,
    symbol       TEXT NOT NULL,
    quantity     TEXT NOT NULL,
    market_value TEXT NOT NULL,
    currency     TEXT NOT NULL,
    PRIMARY KEY (account_id, timestamp, symbol)
);
```

The default extension on `BrokerageProvider` satisfies the protocol's
`portfolioHistory(accountID:range:)` requirement using the provider's injected
`snapshotStore` and `marketData` (§4) — so the signature matches the protocol
and providers get reconstruction for free:

```swift
extension BrokerageProvider {
    public func portfolioHistory(
        accountID: AccountID,
        range: TimeRange
    ) async throws -> PerformanceSeries {
        guard let store = snapshotStore, let market = marketData else {
            throw BrokerageError.unsupported(method: "portfolioHistory")
        }
        // 1. Pull snapshots in range from `store`.
        // 2. If sparse, interpolate by replaying positions × `market` prices.
        //    Symbols that don't resolve in market data are carried at their
        //    last known snapshot value (do not drop the position).
        // 3. Resample to `range.granularity`.
        // 4. Return PerformanceSeries.
    }
}
```

Providers with `.nativePortfolioHistory` (none in v1) override this method
directly and ignore the injected deps.

The host app is expected to call `recordSnapshot` on a schedule (e.g. once
an hour while the app is foregrounded, daily otherwise). The package ships
a small helper, `SnapshotScheduler`, but does *not* manage launch agents
or background tasks; that is the app's job.

---

## 8. Aggregation across providers

```swift
public actor PortfolioAggregator {
    public init(
        providers: [any BrokerageProvider],
        snapshotStore: any SnapshotStore,
        marketData: any MarketDataProvider,
        fx: any FXService = ECBFXService()
    )

    public func allAccounts() async throws -> [Account]
    public func totalValue(in currency: CurrencyCode = .usd) async throws -> Money
    public func combinedHistory(range: TimeRange,
                                in currency: CurrencyCode = .usd) async throws -> PerformanceSeries

    /// Streams updates as providers finish loading. Useful for the macOS
    /// app to show partial results while slow providers (Fidelity) catch up.
    public func liveTotalValues(in currency: CurrencyCode = .usd) -> AsyncThrowingStream<Money, Error>
}

public protocol FXService: Sendable {
    func rate(from: CurrencyCode, to: CurrencyCode, at date: Date) async throws -> Decimal
}
```

`ECBFXService` (the default concrete `FXService`) hits the European Central
Bank reference rates endpoint (free, no auth). For crypto, it falls back to
Coinbase's spot price endpoint. The host may inject any other `FXService`.

---

## 9. Provider implementations

Each provider lives in its own target and depends on `StockChartsKit`. Order
of implementation, from easiest to hardest:

### 9.1 StockChartsKitCSV

A `CSVImportProvider` that reads positions / balances / snapshots from CSV
files in a directory. Useful as both a fallback for unsupported brokerages
and the easiest provider to test against.

- Authentication: none.
- Capabilities: `.positions, .balances`.
- Configurable column mapping per file (`AMD,12,490.70`, etc.).
- Watches the directory with FSEvents and re-loads on change.

### 9.2 StockChartsKitCoinbase

Coinbase has an official API at `https://api.coinbase.com/v2` (and the
newer Advanced Trade API at `/api/v3/brokerage`). Use Advanced Trade.

- Authentication: OAuth 2.0 (PKCE). Scopes: `wallet:accounts:read`,
  `wallet:transactions:read`.
- `listAccounts` -> `GET /api/v3/brokerage/accounts`.
- `positions` -> map each non-zero account to a `Position` with
  `assetClass = .crypto`, symbol like `BTC-USD`.
- `quote` -> `GET /api/v3/brokerage/products/{product_id}/ticker`.
- `priceHistory` -> `GET /api/v3/brokerage/products/{product_id}/candles`
  with granularity mapped from `TimeRange.granularity`.
- Capabilities: `[.positions, .balances, .quotes, .nativePriceHistory, .crypto]`.

### 9.3 StockChartsKitETrade

E*Trade has an official API at `https://api.etrade.com`. The painful part
is OAuth 1.0a (HMAC-SHA1 signed requests).

- Authentication: OAuth 1.0a three-legged.
  1. `GET /oauth/request_token` (signed with consumer secret).
  2. Present `https://us.etrade.com/e/t/etws/authorize?key={ck}&token={rt}` to the user.
  3. User logs in, gets a verifier PIN, pastes back into the app.
  4. `GET /oauth/access_token` exchanges request token + PIN for access token.
  5. Access tokens expire at midnight US Eastern. Refresh via `GET /oauth/renew_access_token`.
- The OAuth 1.0a signer should live in `Sources/StockChartsKitETrade/OAuth1Signer.swift`.
  Use `swift-crypto` for HMAC-SHA1. No third-party OAuth lib.
- `listAccounts` -> `GET /v1/accounts/list.json`.
- `positions` -> `GET /v1/accounts/{accountIdKey}/portfolio.json`.
- `balance` -> `GET /v1/accounts/{accountIdKey}/balance.json?instType=BROKERAGE&realTimeNAV=true`.
- `quote` -> `GET /v1/market/quote/{symbol}.json`.
- E*Trade does not expose price history; `priceHistory` throws `.unsupported`.
- Capabilities: `[.positions, .balances, .quotes]`.

Sandbox base URL is `https://apisb.etrade.com`. Expose both via a
`Configuration` initializer.

### 9.4 StockChartsKitSchwab

Schwab launched a developer API after absorbing TD Ameritrade. OAuth 2.0,
much cleaner than E*Trade.

- Authentication: OAuth 2.0, client credentials registered via the Schwab
  developer portal.
- Endpoints under `https://api.schwabapi.com/trader/v1/`.
- `priceHistory` is supported natively via `/marketdata/v1/pricehistory`.
- Capabilities: `[.positions, .balances, .quotes, .nativePriceHistory]`.

### 9.5 StockChartsKitSnapTrade

This is the workhorse. SnapTrade is a brokerage aggregator that covers
Robinhood, Fidelity (retail and NetBenefits), Acorns, Vanguard,
Wealthfront, Webull, Public, Wells Fargo, and dozens more under one API.
The free tier supports up to 5 connections, which is enough for a
personal portfolio.

The implementation exposes *one provider per connected brokerage*, not
one global SnapTrade provider. The factory function `SnapTradeProviders.discover()`
returns an array of `BrokerageProvider` instances, one per `Connection`
the user has registered.

- Authentication:
  1. Register the package's `clientId` and `consumerKey` with SnapTrade.
  2. Register the end user via `POST /api/v1/snapTrade/registerUser`.
  3. Generate a login URL via `POST /api/v1/snapTrade/login` and present
     it in a web view (`AuthChallenge.hostedPortal`).
  4. Persist `userId` + `userSecret` in Keychain.
- Endpoints (under `https://api.snaptrade.com/api/v1`):
  - `GET /accounts` -> map to `[Account]`.
  - `GET /accounts/{id}/positions` -> `[Position]`.
  - `GET /accounts/{id}/balances` -> `Balance`.
  - `GET /accounts/{id}/activities` -> available for snapshot reconstruction.
- All SnapTrade requests require a SHA-256 HMAC signature in the
  `Signature` header. Signer lives in `Sources/StockChartsKitSnapTrade/Signing.swift`.
- Provider IDs are namespaced: `snaptrade.robinhood`, `snaptrade.fidelity`,
  `snaptrade.acorns`, etc. The brokerage name comes from the `Account.brokerage_authorization`
  field on SnapTrade.
- Capabilities: `[.positions, .balances]`. SnapTrade does not expose
  per-symbol price history; rely on `MarketDataProvider`.

#### Fidelity / NetBenefits note

SnapTrade's Fidelity integration uses a single Fidelity login and surfaces
whatever accounts that login can see. Brennan: in practice, your retail
Fidelity login on `fidelity.com` typically sees both retail brokerage and
NetBenefits workplace accounts. If your employer's NetBenefits requires a
separate login, that path will not work and you'll need a second
connection. The provider should not assume; just enumerate whatever
SnapTrade returns.

### 9.6 Out of scope for v1

- Robinhood direct (unofficial API; bans). Route through SnapTrade.
- Acorns direct. No public API. Route through SnapTrade.
- Vanguard direct. No public API. Route through SnapTrade.
- Apple Card / Cash. No API at all.

---

## 10. Errors

```swift
public enum BrokerageError: Error, Sendable {
    case notAuthenticated
    case authenticationFailed(reason: String)
    case authorizationRevoked
    case rateLimited(retryAfter: Date?)
    case unsupported(method: String)
    case currencyMismatch(lhs: CurrencyCode, rhs: CurrencyCode)
    case providerError(providerID: ProviderID, statusCode: Int?, message: String)
    case decodingFailed(underlying: Error)
    case network(underlying: Error)
    case missingSymbol(Symbol)
    case stale(asOf: Date)
}
```

Every provider must map its native errors into one of these cases. Provider
implementations may attach extra context via `providerError`.

---

## 11. Networking

- No third-party HTTP client. Use `URLSession` with `data(for:)`.
- Wrap requests in a small `HTTPClient` actor per provider that handles:
  - Bearer / OAuth signing in a single interception point.
  - Retry-with-backoff on 429 and 5xx (max 3 attempts, exponential).
  - `Retry-After` header parsing.
  - Decoding JSON with a configured `JSONDecoder` (snake_case to camelCase,
    ISO 8601 dates, `Decimal` from string).
- All public methods are cancellation-aware (`Task.checkCancellation()` at
  the start, and `URLSession` tasks are cancelled via structured concurrency).

---

## 12. Testing

- `StockChartsKitTesting` library target with:
  - `MockBrokerageProvider`: programmable conformance for tests.
  - `InMemorySnapshotStore`: an in-memory `SnapshotStore` for unit tests.
  - `FixedMarketDataProvider`: returns canned `PerformanceSeries`.
- Per-provider tests use **HTTP replay**: record real responses (redacted)
  into JSON fixtures under `Tests/.../Fixtures/`, replay via a custom
  `URLProtocol` subclass. Do not commit live tokens.
- `swift test` must pass on macOS 14 with no network access.
- Property-based tests on `Money` arithmetic and `TimeRange.interval`
  rollover (DST, year boundary, leap day) using `swift-testing`.

---

## 13. Dependencies

Pinned in `Package.swift`. Keep this list short.

| Package | Purpose | Notes |
|---|---|---|
| `swift-crypto` | HMAC for OAuth 1.0a, SnapTrade signing | Apple, stable |
| `GRDB.swift` | SQLite snapshot store | `groue/GRDB.swift` |
| `swift-collections` | `OrderedDictionary` for time series | Apple |
| `swift-testing` | New test runner | Comes with Swift 6 toolchain |

No Alamofire. No KeychainAccess (write it directly). No SwiftJWT. No Vapor.

---

## 14. Style and conventions

- Two-space indentation, max 100-col lines, run `swift-format` with default
  config on commit.
- Public API: full DocC comments with at least a one-line summary and a
  `## Example` section where non-obvious.
- No `@objc`. No `NSObject` subclasses.
- No `print()`. Use `os.Logger` with subsystem `co.sstools.stockchartskit`
  and per-target categories. (Domain: `sstools.co`, reverse-DNS.)
- Prefer `throws(SomeError)` typed throws where the error space is closed
  (e.g. signing helpers).
- No force-unwraps in production code except for static, provably-non-nil
  constants (regex literals, URL string literals checked at init).
- Prefer `Foundation.Decimal` over `Double` everywhere money or quantity
  is involved.

---

## 15. README

Generate a `README.md` at the package root with:

1. One-paragraph description.
2. Quick-start example: register a `Coinbase` and a `SnapTrade` provider,
   aggregate, print total + 1-year history.
3. Capabilities matrix (provider × capability).
4. Auth setup notes per provider, including where to register a developer
   app for E*Trade, Coinbase, Schwab, SnapTrade.
5. Caveats: snapshot store needs to be wound regularly, Yahoo fallback is
   unofficial, NetBenefits separate-login limitation, Tiingo free-tier quota.
6. Secrets policy: developer-app credentials and per-user tokens are supplied
   at runtime from the macOS Keychain and never hardcoded; the app is
   local/non-distributed, and shipping it would require moving secrets behind
   a backend proxy first (§5.1).

---

## 16. Example usage (include in README)

```swift
import StockChartsKit
import StockChartsKitCoinbase
import StockChartsKitETrade
import StockChartsKitSnapTrade
import StockChartsKitMarketData

// All secrets come from the Keychain (seeded during onboarding) — never
// hardcoded. `keychain` is the package's KeychainStore; `secret(_:)` is a
// host helper that reads one item and returns its value.
let keychain = KeychainStore(service: Bundle.main.bundleIdentifier!)

let snapshotStore = try SQLiteSnapshotStore(url: .documentsDirectory.appending(path: "snapshots.sqlite"))
let marketData = TieredMarketDataProvider(
    primary: TiingoMarketData(apiKey: try await keychain.secret("tiingo.apiKey")),
    fallback: YahooFinanceMarketData()
)

let providers: [any BrokerageProvider] = [
    CoinbaseProvider(                                   // PKCE — no client secret
        configuration: .init(secrets: ["clientID": try await keychain.secret("coinbase.clientID")]),
        snapshotStore: snapshotStore, marketData: marketData),
    ETradeProvider(
        configuration: .init(secrets: [
            "consumerKey": try await keychain.secret("etrade.consumerKey"),
            "consumerSecret": try await keychain.secret("etrade.consumerSecret"),
        ]),
        environment: .production,
        snapshotStore: snapshotStore, marketData: marketData),
    // SnapTrade: one provider per connection
] + (try await SnapTradeProviders.discover(
        configuration: .init(secrets: [
            "clientId": try await keychain.secret("snaptrade.clientId"),
            "consumerKey": try await keychain.secret("snaptrade.consumerKey"),
        ]),
        snapshotStore: snapshotStore, marketData: marketData))

let aggregator = PortfolioAggregator(
    providers: providers,
    snapshotStore: snapshotStore,
    marketData: marketData
)

let total = try await aggregator.totalValue()
print("Net worth: \(total)")

let series = try await aggregator.combinedHistory(range: .threeMonths)
// Hand this to Swift Charts in the macOS app.
```

---

## 17. File-by-file checklist

Claude Code should create these files in this order. Each item is one PR-sized
unit.

1. `Package.swift` with all targets and dependencies declared.
2. `Sources/StockChartsKit/Models/Money.swift` + tests.
3. `Sources/StockChartsKit/Models/TimeRange.swift` + tests (cover DST, YTD).
4. All remaining model files in `Sources/StockChartsKit/Models/`.
5. `Sources/StockChartsKit/Errors/BrokerageError.swift`.
6. `Sources/StockChartsKit/Auth/*` (challenges, sessions, Keychain).
7. `Sources/StockChartsKit/Protocols/BrokerageProvider.swift` (the protocol).
8. `Sources/StockChartsKit/Protocols/MarketDataProvider.swift`.
9. `Sources/StockChartsKit/Protocols/SnapshotStore.swift`.
10. `Sources/StockChartsKit/Snapshot/SQLiteSnapshotStore.swift` + tests.
11. `Sources/StockChartsKit/Aggregation/PortfolioAggregator.swift` + tests.
12. `Sources/StockChartsKitTesting/MockBrokerageProvider.swift`.
13. `Sources/StockChartsKitMarketData/` (Tiingo + Yahoo + tiered).
14. `Sources/StockChartsKitCSV/` (easiest provider, prove the protocol works).
15. `Sources/StockChartsKitCoinbase/`.
16. `Sources/StockChartsKitETrade/` including `OAuth1Signer`.
17. `Sources/StockChartsKitSchwab/`.
18. `Sources/StockChartsKitSnapTrade/` including signer and connection discovery.
19. `README.md`.

After each file, run `swift build` and `swift test`. Do not move on until
both pass.

---

## 18. What not to do

- Do not add a Combine layer. Async/await only.
- Do not add UI. No SwiftUI views, no `Charts` integration. The host app
  handles rendering.
- Do not try to write to brokerages. No trade placement, no transfers.
- Do not invent a custom Decimal type. Use `Foundation.Decimal`.
- Do not log tokens, even at debug level.
- Do not hardcode API keys or secrets in source — ever, including fixtures
  and defaults. Secrets reach a provider only through the host's
  `Configuration` (developer-app credentials) or `KeychainStore` (per-user
  tokens), both seeded from the macOS Keychain at runtime (§5.1).
- Do not silently cache stale data without surfacing `asOf` to the caller.
- Do not promise per-symbol history on providers that lack it. Throw
  `.unsupported` and let the host fall through to `MarketDataProvider`.
