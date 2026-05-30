# StockChartsKit

A Swift 6 package exposing a unified, **read-only** `BrokerageProvider` protocol for reading portfolio data — accounts, positions, balances, quotes, per-symbol price history, and reconstructed portfolio-value history — from multiple brokerages (Coinbase, E\*Trade, Schwab, and dozens more via SnapTrade) plus a CSV-import fallback, then aggregating it across providers into a single currency for charting in a macOS app. Money and quantities use `Foundation.Decimal` end-to-end; all networking is `async`/`await` over `URLSession`; no trading or write operations exist in v1.

## Requirements

- **macOS 14+**
- **Swift 6.1+** (the package builds with `swift-tools-version: 6.3` in full Swift 6 language mode / strict concurrency)
- Xcode 16+ or a matching Swift toolchain

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/brennanMKE/StockChartsKit.git", from: "1.0.0")
]
```

There is **one library product per provider**, so a host links only what it needs:

| Product | Contents |
|---|---|
| `StockChartsKit` | Core: models, `BrokerageProvider`/`MarketDataProvider`/`SnapshotStore` protocols, `PortfolioAggregator`, `SQLiteSnapshotStore`, `SnapshotScheduler`, `KeychainStore`, `Configuration`, FX |
| `StockChartsKitMarketData` | `TiingoMarketData`, `YahooFinanceMarketData`, `TieredMarketDataProvider` |
| `StockChartsKitCSV` | `CSVImportProvider` |
| `StockChartsKitCoinbase` | `CoinbaseProvider` |
| `StockChartsKitETrade` | `ETradeProvider` |
| `StockChartsKitSchwab` | `SchwabProvider` |
| `StockChartsKitSnapTrade` | `SnapTradeProviders` (one provider per connected brokerage) |
| `StockChartsKitTesting` | HTTP-replay support for tests |

Depend on, for example, only `StockChartsKit`, `StockChartsKitMarketData`, and `StockChartsKitCoinbase` if Coinbase is the only brokerage you support.

## Quick start

All developer-app credentials and per-user tokens are read from the macOS **Keychain at runtime** — nothing is ever hardcoded. `KeychainStore` is the package's actor wrapping the Security framework; it conforms to each provider's `TokenStore` protocol, so the same instance both feeds developer-app secrets into a `Configuration` (via a host read) and persists per-user OAuth tokens.

```swift
import StockChartsKit
import StockChartsKitMarketData
import StockChartsKitCoinbase
import StockChartsKitSnapTrade

// `keychain.secret(_:)` reads one Keychain item (seeded during onboarding) and
// returns its value, or throws `BrokerageError.notAuthenticated` if missing.
// It is the package API — no host helper required.
let keychain = KeychainStore(service: Bundle.main.bundleIdentifier!)

// Snapshot store: parent directory must already exist.
let dbURL = URL.documentsDirectory.appending(path: "snapshots.sqlite")
let snapshotStore = try SQLiteSnapshotStore(url: dbURL)

// Market data: Tiingo primary, Yahoo fallback. The tiered provider caches
// daily bars to stay under Tiingo's free-tier quota (see Caveats).
let marketData = TieredMarketDataProvider(
    primary: TiingoMarketData(apiKey: try await keychain.secret("tiingo.apiKey")),
    fallback: YahooFinanceMarketData()
)

// Coinbase: OAuth 2.0 with PKCE — a client ID and redirect URI, no secret.
let coinbase = try CoinbaseProvider(
    configuration: .init(secrets: [
        "clientID": try await keychain.secret("coinbase.clientID"),
        "redirectURI": try await keychain.secret("coinbase.redirectURI"),
    ]),
    tokenStore: keychain,
    snapshotStore: snapshotStore,
    marketData: marketData
)

// SnapTrade: developer-app credentials are clientId + consumerKey. The user
// must already have been registered (`registerUser`) and connected through the
// hosted portal (`loginChallenge`) during onboarding — `discover` then returns
// one BrokerageProvider per connected brokerage (Robinhood, Fidelity, ...).
let snapTradeConfig = Configuration(secrets: [
    "clientId": try await keychain.secret("snaptrade.clientId"),
    "consumerKey": try await keychain.secret("snaptrade.consumerKey"),
])
let snapTradeProviders = try await SnapTradeProviders.discover(
    configuration: snapTradeConfig,
    tokenStore: keychain,
    snapshotStore: snapshotStore,
    marketData: marketData
)

let providers: [any BrokerageProvider] = [coinbase] + snapTradeProviders

let aggregator = PortfolioAggregator(
    providers: providers,
    snapshotStore: snapshotStore,
    marketData: marketData
)

// Current net worth, FX-converted into USD.
let total = try await aggregator.totalValue(in: .usd)
print("Net worth: \(total)")

// Reconstructed, FX-converted portfolio-value history. `combinedHistory`
// merges every account's series onto one time axis.
let oneYear = try await aggregator.combinedHistory(range: .oneYear)
let threeMonths = try await aggregator.combinedHistory(range: .threeMonths)
// Hand the `points` to Swift Charts in the macOS app.
```

> **Note (corrected vs PRD §16).** The shipped API differs from the PRD's
> illustrative snippet in a few ways: each provider's initializer takes a
> `tokenStore` (pass `keychain`) separate from the `snapshotStore`; Coinbase
> and Schwab also require a `"redirectURI"` secret; `SnapTradeProviders.discover`
> takes `tokenStore:` and assumes the user is already registered and connected;
> and the aggregator method is `combinedHistory(range:)` (there is no
> `oneYearHistory`). Each provider initializer is `throws` because it validates
> required configuration keys up front.

To keep per-account history dense for providers that only return current state, run the snapshot scheduler on a cadence the host controls:

```swift
let scheduler = SnapshotScheduler(
    providers: providers,
    store: snapshotStore,
    interval: .seconds(3600)   // hourly while foregrounded, for example
)
await scheduler.start()   // ...and `await scheduler.stop()` on resign-active.
```

## Capabilities matrix

Each provider declares its real capabilities via `capabilities` in source. "Native price history" / "native portfolio history" mean the brokerage's own API serves that data; where it is absent, the package falls back to the injected `MarketDataProvider` (price history) and `SnapshotStore` reconstruction (portfolio history).

| Provider | Positions | Balances | Quotes | Native price history | Native portfolio history | Crypto |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| CSV import | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| Coinbase | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ |
| E\*Trade | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ |
| Schwab | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| SnapTrade | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |

No provider ships native **portfolio-value** history; that series is always reconstructed from recorded snapshots, so winding the snapshot store regularly matters (see Caveats).

## Authentication setup per provider

Each provider drives its own auth dance. The host presents the `AuthChallenge` the package returns (`oauthRedirect`, `pinCode`, or `hostedPortal`) and writes the resulting per-user tokens into the Keychain. Developer-app credentials are passed to each provider through `Configuration`.

### CSV import
No auth, no developer app. Point `CSVImportProvider` at a directory containing `positions.csv` and `balances.csv`; it loads on init and (optionally) watches the directory for changes.

### Coinbase — OAuth 2.0 with PKCE (no client secret)
- **Register an app:** [Coinbase Developer Platform / OAuth apps](https://www.coinbase.com/settings/api) (`login.coinbase.com/oauth2`). Configure your redirect URI / callback scheme.
- **Credentials needed:** `clientID` and `redirectURI` only — **no client secret** (PKCE).
- **UX:** `AuthChallenge.oauthRedirect` — open the authorization URL, capture the redirect, and the provider exchanges the code (PKCE verifier) for tokens, persisted in the Keychain.

### E\*Trade — OAuth 1.0a (PIN)
- **Register an app:** [E\*Trade Developer Portal](https://developer.etrade.com/) to obtain a consumer key/secret (request production keys for live data).
- **Credentials needed:** `consumerKey` and `consumerSecret`. Choose `.production` or `.sandbox` via the `environment:` parameter.
- **UX:** `AuthChallenge.pinCode` — the user opens the authorize URL, approves, and pastes the verifier PIN back into the app; the provider exchanges it for an access token/secret.

### Schwab — OAuth 2.0 (Basic-auth token exchange)
- **Register an app:** [Schwab Developer Portal](https://developer.schwab.com/) (`api.schwabapi.com`).
- **Credentials needed:** `clientID`, `clientSecret`, and `redirectURI`. The token exchange uses HTTP Basic auth with the client id/secret.
- **UX:** `AuthChallenge.oauthRedirect` — open the authorization URL, capture the redirect, exchange the code for tokens (refresh token persisted in the Keychain).

### SnapTrade — hosted connection portal
SnapTrade is a brokerage aggregator covering Robinhood, Fidelity (retail and NetBenefits), Acorns, Vanguard, Webull, Public, and more. The package exposes **one provider per connected brokerage**, not one global provider.
- **Register an app:** [SnapTrade dashboard](https://dashboard.snaptrade.com/) for a `clientId` and `consumerKey`. Every request is signed with a SHA-256 HMAC.
- **Credentials needed:** `clientId` and `consumerKey` (developer-app); per-user `userId`/`userSecret` are obtained at runtime.
- **Onboarding flow:**
  1. `SnapTradeProviders.registerUser(userId:configuration:tokenStore:)` — registers the end user and persists `userId`/`userSecret`.
  2. `SnapTradeProviders.loginChallenge(configuration:tokenStore:)` — returns `AuthChallenge.hostedPortal(url:)`; present it in a web view so the user connects their brokerages.
  3. `SnapTradeProviders.discover(configuration:tokenStore:snapshotStore:marketData:)` — enumerates connections and returns one `BrokerageProvider` each, with namespaced IDs like `snaptrade.robinhood`.

## Caveats

- **Wind the snapshot store regularly.** No brokerage serves native portfolio-value history, so per-account history is reconstructed from recorded snapshots. If you do not run `SnapshotScheduler` (or call `recordSnapshot` / `recordOnce` on a cadence), history will be sparse — you only get points for the moments you actually snapshotted. Pick a cadence (e.g. hourly while foregrounded, daily otherwise) and call `prune(olderThan:)` to bound growth.
- **Yahoo fallback is unofficial.** `YahooFinanceMarketData` uses the undocumented `query1.finance.yahoo.com/v8/finance/chart` endpoint. It needs no auth and is widely used, but it is an undocumented endpoint with no stability or terms guarantee — a **legal grey area**, treated as best-effort only. Prefer Tiingo (or any provider you supply) as the primary; Yahoo is a convenience fallback.
- **NetBenefits separate-login limitation.** SnapTrade's Fidelity integration uses a single Fidelity login and surfaces whatever accounts that login can see. A retail `fidelity.com` login typically also sees NetBenefits workplace accounts — but if your employer's NetBenefits requires a *separate* login, those accounts will not appear under the retail connection and you'll need a second SnapTrade connection. The provider makes no assumption; it enumerates whatever SnapTrade returns.
- **Tiingo free-tier quota.** Tiingo's free tier allows roughly **500 symbols/month** of daily prices. `TieredMarketDataProvider` caches fetched daily bars (via an injectable `DailyBarCache`) and serves cache-first for daily granularity, hitting the network only for missing/stale ranges, which keeps a multi-symbol portfolio comfortably under quota. Intraday data is fetched live.

## Secrets policy

**No secret is ever hardcoded in source — not in defaults, not in fixtures, not at debug level.** This is a hard rule. Two kinds of secret exist and both are supplied at runtime by the host app from the macOS Keychain:

1. **Developer-app credentials** — the per-provider keys registered with each brokerage's developer portal (E\*Trade `consumerKey`/`consumerSecret`, Coinbase `clientID`, Schwab `clientID`/`clientSecret`, SnapTrade `clientId`/`consumerKey`). The host reads them from the Keychain and passes them into each provider's `Configuration` at launch.
2. **Per-user tokens** — OAuth access/refresh tokens, SnapTrade `userId`/`userSecret`, obtained during the auth dance and read/written through `KeychainStore`.

The package never reads secrets from the environment or disk on its own, and never logs token values. This app is **local, single-machine, and non-distributed**: developer-app secrets live only in the user's own Keychain, which is safe for a personal app.

> **Distribution caveat.** Because there is no backend, developer-app secrets sit in the user's Keychain on their own machine. If this app is ever **distributed**, those developer-app secrets must move behind a **backend proxy** first — revisit before shipping.

## Testing

`swift test` runs the full suite **fully offline**: every provider and market-data test replays recorded HTTP fixtures via `StockChartsKitTesting` and uses no live tokens or network access.
