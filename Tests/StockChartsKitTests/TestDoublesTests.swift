import Foundation
import Testing

@testable import StockChartsKit
import StockChartsKitTesting

@Suite("MockBrokerageProvider")
struct MockBrokerageProviderTests {
  private let providerID = ProviderID(rawValue: "test")

  private func account(_ raw: String) -> Account {
    Account(
      id: AccountID(rawValue: raw),
      providerID: providerID,
      displayName: "Test \(raw)",
      kind: .brokerage,
      baseCurrency: .usd,
      connectionID: nil
    )
  }

  @Test("nonisolated identity is exposed without actor hops")
  func identity() {
    let mock = MockBrokerageProvider(
      id: providerID,
      displayName: "Test Broker",
      capabilities: [.positions, .quotes]
    )
    #expect(mock.id == providerID)
    #expect(mock.displayName == "Test Broker")
    #expect(mock.capabilities.contains(.positions))
    #expect(mock.capabilities.contains(.quotes))
  }

  @Test("defaults are unsupported / empty")
  func defaults() async throws {
    let mock = MockBrokerageProvider(id: providerID)
    let accounts = try await mock.listAccounts()
    #expect(accounts.isEmpty)
    if case .error(.notAuthenticated) = await mock.authenticationStatus() {
      // ok
    } else {
      Issue.record("expected .error(.notAuthenticated) by default")
    }
    await #expect(throws: BrokerageError.self) {
      _ = try await mock.quote(for: Symbol(rawValue: "AMD"))
    }
  }

  @Test("canned and throwing behaviour is injectable")
  func injection() async throws {
    let mock = MockBrokerageProvider(id: providerID)
    await mock.setAccounts([account("a1")])
    await mock.setQuote { symbol in
      Quote(symbol: symbol, last: .usd(42), previousClose: nil, asOf: .now)
    }
    await mock.setBalance { _ in throw BrokerageError.rateLimited(retryAfter: nil) }

    let accounts = try await mock.listAccounts()
    #expect(accounts.count == 1)
    let quote = try await mock.quote(for: Symbol(rawValue: "AMD"))
    #expect(quote.last == .usd(42))
    await #expect(throws: BrokerageError.self) {
      _ = try await mock.balance(for: AccountID(rawValue: "a1"))
    }
  }
}

@Suite("InMemorySnapshotStore")
struct InMemorySnapshotStoreTests {
  private let providerA = ProviderID(rawValue: "alpha")
  private let providerB = ProviderID(rawValue: "beta")

  private func snapshot(_ account: String, at offset: TimeInterval) -> PortfolioSnapshot {
    PortfolioSnapshot(
      accountID: AccountID(rawValue: account),
      timestamp: Date(timeIntervalSince1970: offset),
      totalValue: .usd(1000),
      positions: []
    )
  }

  @Test("records and returns snapshots oldest-first for an account")
  func recordAndQueryByAccount() async throws {
    let store = InMemorySnapshotStore()
    try await store.recordSnapshot(snapshot("a1", at: 200))
    try await store.recordSnapshot(snapshot("a1", at: 100))
    try await store.recordSnapshot(snapshot("a2", at: 150))

    let interval = DateInterval(
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 1000)
    )
    let a1 = try await store.snapshots(accountID: AccountID(rawValue: "a1"), in: interval)
    #expect(a1.count == 2)
    #expect(a1.first?.timestamp == Date(timeIntervalSince1970: 100))
    #expect(a1.last?.timestamp == Date(timeIntervalSince1970: 200))
  }

  @Test("providerID filtering uses the injected account mapping")
  func filterByProvider() async throws {
    let store = InMemorySnapshotStore(accountProviders: [
      AccountID(rawValue: "a1"): providerA,
      AccountID(rawValue: "a2"): providerB,
    ])
    try await store.recordSnapshot(snapshot("a1", at: 100))
    try await store.recordSnapshot(snapshot("a2", at: 110))
    // Unmapped account: included only in the nil-provider query.
    try await store.recordSnapshot(snapshot("a3", at: 120))

    let interval = DateInterval(
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 1000)
    )
    let alpha = try await store.snapshots(providerID: providerA, in: interval)
    #expect(alpha.count == 1)
    #expect(alpha.first?.accountID == AccountID(rawValue: "a1"))

    let all = try await store.snapshots(providerID: nil, in: interval)
    #expect(all.count == 3)
  }

  @Test("prune removes snapshots older than the cutoff")
  func prune() async throws {
    let store = InMemorySnapshotStore()
    try await store.recordSnapshot(snapshot("a1", at: 100))
    try await store.recordSnapshot(snapshot("a1", at: 300))
    try await store.prune(olderThan: Date(timeIntervalSince1970: 200))

    let interval = DateInterval(
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 1000)
    )
    let remaining = try await store.snapshots(accountID: AccountID(rawValue: "a1"), in: interval)
    #expect(remaining.count == 1)
    #expect(remaining.first?.timestamp == Date(timeIntervalSince1970: 300))
  }
}

@Suite("FixedMarketDataProvider")
struct FixedMarketDataProviderTests {
  @Test("returns the canned price for quotes and history")
  func cannedData() async throws {
    let provider = FixedMarketDataProvider(price: .usd(250))
    let quote = try await provider.quote(symbol: Symbol(rawValue: "AMD"))
    #expect(quote.last == .usd(250))

    let series = try await provider.priceHistory(
      symbol: Symbol(rawValue: "AMD"),
      range: .oneMonth
    )
    #expect(series.subject == .symbol(Symbol(rawValue: "AMD")))
    #expect(series.points.allSatisfy { $0.value == .usd(250) })
    #expect(series.granularity == TimeRange.oneMonth.granularity)
  }
}

@Suite("Redactor")
struct RedactorTests {
  @Test("scrubs known keys and literal values at any depth")
  func redaction() throws {
    let raw = """
      {"access_token":"live-abc","user":{"email":"a@b.com","plan":"pro"},"n":42}
      """
    let redactor = Redactor(redactValues: ["pro"])
    let out = redactor.redact(Data(raw.utf8))
    let object = try JSONSerialization.jsonObject(with: out) as? [String: Any]
    let user = object?["user"] as? [String: Any]
    #expect(object?["access_token"] as? String == "REDACTED")
    #expect(user?["email"] as? String == "REDACTED")
    #expect(user?["plan"] as? String == "REDACTED")
    #expect(object?["n"] as? Int == 42)
  }
}
