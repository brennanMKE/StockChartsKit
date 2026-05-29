/// Test-support library for StockChartsKit.
///
/// Provides programmable test doubles (``MockBrokerageProvider``,
/// ``InMemorySnapshotStore``, ``FixedMarketDataProvider``) and an offline
/// HTTP-replay stack (``ReplayURLProtocol``, ``FixtureStore``, ``HTTPFixture``,
/// ``Redactor``) so every provider test runs without network access.
public enum StockChartsKitTesting {}
