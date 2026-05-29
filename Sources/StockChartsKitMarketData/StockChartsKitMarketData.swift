/// Default market-data providers for StockChartsKit.
///
/// This target supplies the package's default ``MarketDataProvider`` stack
/// (PRD §6):
///
/// - ``TiingoMarketData`` — the primary source, best for daily charts.
/// - ``YahooFinanceMarketData`` — the unauthenticated, best-effort fallback.
/// - ``TieredMarketDataProvider`` — the default composite that tries the primary
///   first, falls back on any error, and caches daily bars to stay under quota.
///
/// A host typically builds the composite directly; this enum exists only as a
/// documentation anchor for the module.
public enum StockChartsKitMarketData {}
