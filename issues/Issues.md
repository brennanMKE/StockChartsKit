# StockChartsKit

A Swift 6 package exposing a unified `BrokerageProvider` protocol for reading read-only portfolio data (accounts, positions, balances, quotes, price history, portfolio-value history) from multiple brokerages — E*Trade, Coinbase, SnapTrade (Robinhood / Fidelity / Acorns / …), Schwab — plus a CSV-import fallback. Consumed by a macOS app that renders charts with Swift Charts. macOS only for v1.

This file is the local guide for managing issues in this project. The companion Mac app (Issues.app) watches the `issues/` folder and renders the current state. Markdown files (and `project.json`) are the source of truth — there is no generated artifact or index to keep in sync.

The issues currently tracked here are the **implementation tasks** derived from `PRD.md`, broken down into PR-sized units roughly following the file-by-file checklist in PRD §17. Each is filed as `open`.

## Status values

| File value | Display name | Meaning |
|---|---|---|
| `open` | Open | Filed but not yet started |
| `in-progress` | In Progress | Actively being worked on |
| `resolved` | Resolved | Work is done; awaiting user confirmation |
| `closed` | Closed | User has confirmed the fix |
| `wontfix` | Won't Fix | Acknowledged but won't be addressed |

Use the **file value** (lowercase, hyphenated) in the issue's metadata table.

## Critical rule: never close without explicit confirmation

An issue must **never** be marked `resolved`, `closed`, or `wontfix` based on inference — only when the user says so in plain language. A subagent that finishes a task may set `resolved` (work done, not yet confirmed); only the user moves an issue to `closed`.

## Git tracking

`issues/` is tracked in git for this project. Each lifecycle event produces a commit:

| Event | What's committed | Commit message |
|---|---|---|
| File a new issue | the new `NNNN.md` | `#NNNN <issue title>` |
| Resolve — code commit | code changes only | `#NNNN <verb> <title>` |
| Resolve — resolution commit | markdown update | `#NNNN Resolve: <title>` |
| Bail with notes | markdown only | `#NNNN Notes: <brief>` |
| User-confirmed close | markdown only | `#NNNN Close` |
| Won't fix | markdown only | `#NNNN Won't fix` |

Setting status to `in-progress` at the start of work is a transient working-copy edit and is not committed on its own.

## Build / verify command for this project

Per PRD §17: after each unit of work, run **`swift build`** and **`swift test`**. Do not mark an issue `resolved` until both pass with the relevant tests actually executing. `swift test` must pass on macOS 14 with no network access (per-provider tests use HTTP replay fixtures, never live tokens — PRD §12).

## Module conventions for this project

Use these canonical module / area names so issues stay consistent (they map to the package targets and PRD sections):

- `Packaging` — `Package.swift`, targets, products, dependencies
- `Core/Models` — `Sources/StockChartsKit/Models/*`
- `Core/Errors` — `BrokerageError`
- `Core/Auth` — `AuthChallenge`, `AuthSession`, `KeychainStore`
- `Core/Protocols` — `BrokerageProvider`, `MarketDataProvider`, `SnapshotStore`
- `Core/Snapshot` — `SQLiteSnapshotStore`, snapshot reconstruction
- `Core/Aggregation` — `PortfolioAggregator`, `FXService`
- `Core/Networking` — shared `HTTPClient`
- `Testing` — `StockChartsKitTesting` support library
- `MarketData` — `StockChartsKitMarketData` (Tiingo + Yahoo)
- `CSV`, `Coinbase`, `ETrade`, `Schwab`, `SnapTrade` — provider targets
- `Docs` — `README.md`

## Hard rules carried from the PRD

- **No secrets in source — ever** (PRD §5.1, §18). Not in fixtures, defaults, or debug. Secrets reach providers only through `Configuration` (developer-app credentials) or `KeychainStore` (per-user tokens).
- Async/await only — no Combine, no callbacks. Swift 6 strict concurrency.
- `Foundation.Decimal` for all money/quantity — never `Double`.
- No third-party HTTP client; `URLSession` only. Allowed deps: `swift-crypto`, `GRDB.swift`, `swift-collections`, `swift-testing`.
- No `print()` — use `os.Logger`, subsystem `co.sstools.stockchartskit`. Never log tokens.
- Read-only — no trading/write capabilities in v1.
