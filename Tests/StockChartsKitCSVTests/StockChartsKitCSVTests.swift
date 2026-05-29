import Foundation
import Testing

import StockChartsKit
@testable import StockChartsKitCSV

// MARK: - Helpers

/// Creates a unique temporary directory for a test and returns its URL.
private func makeTempDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("csvtests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func write(_ text: String, to url: URL) throws {
  try text.write(to: url, atomically: true, encoding: .utf8)
}

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
private let fixedClock: @Sendable () -> Date = { fixedDate }

// MARK: - Parser: positions

@Test func parsesPositionalPositions() throws {
  let parser = CSVPortfolioParser(fallbackAccountID: AccountID(rawValue: "acct"))
  let csv = """
  AMD,12,490.70
  NVDA,5,1200.00
  """
  let positions = parser.positions(from: csv, asOf: fixedDate)

  #expect(positions.count == 2)

  let amd = try #require(positions.first { $0.symbol == Symbol(rawValue: "AMD") })
  #expect(amd.quantity == Decimal(12))
  // marketValue = quantity * price = 12 * 490.70 = 5888.40
  #expect(amd.marketValue.amount == Decimal(string: "5888.40"))
  #expect(amd.accountID == AccountID(rawValue: "acct"))
  #expect(amd.assetClass == .equity)

  let nvda = try #require(positions.first { $0.symbol == Symbol(rawValue: "NVDA") })
  #expect(nvda.quantity == Decimal(5))
  #expect(nvda.marketValue.amount == Decimal(string: "6000.00"))
}

@Test func parsesHeaderBasedPositionsWithMarketValueAndAccount() throws {
  let parser = CSVPortfolioParser(fallbackAccountID: AccountID(rawValue: "fallback"))
  let csv = """
  account,symbol,quantity,marketValue,averageCost,assetClass
  IRA-1,VOO,10.5,5000.00,400.00,etf
  IRA-1,BTC-USD,0.25,15000.00,,crypto
  """
  let positions = parser.positions(
    from: csv,
    mapping: .defaultPositionsHeader,
    asOf: fixedDate
  )

  #expect(positions.count == 2)

  let voo = try #require(positions.first { $0.symbol == Symbol(rawValue: "VOO") })
  #expect(voo.accountID == AccountID(rawValue: "IRA-1"))
  #expect(voo.quantity == Decimal(string: "10.5"))
  #expect(voo.marketValue.amount == Decimal(string: "5000.00"))
  #expect(voo.averageCost?.amount == Decimal(string: "400.00"))
  #expect(voo.assetClass == .etf)

  let btc = try #require(positions.first { $0.symbol == Symbol(rawValue: "BTC-USD") })
  #expect(btc.assetClass == .crypto)
  #expect(btc.averageCost == nil)
}

@Test func skipsMalformedAndBlankPositionRows() throws {
  let parser = CSVPortfolioParser(fallbackAccountID: AccountID(rawValue: "acct"))
  let csv = """
  AMD,12,490.70

  GARBAGE_ROW
  NVDA,notanumber,100
  TSLA,3,250.00
  """
  let positions = parser.positions(from: csv, asOf: fixedDate)
  // Only AMD and TSLA are well-formed.
  #expect(positions.count == 2)
  #expect(positions.map(\.symbol.rawValue).sorted() == ["AMD", "TSLA"])
}

@Test func handlesQuotedFieldsWithCommas() throws {
  let parser = CSVPortfolioParser(fallbackAccountID: AccountID(rawValue: "acct"))
  let csv = """
  account,symbol,quantity,marketValue
  "Brokerage, Joint",AAPL,100,"18000.00"
  """
  let positions = parser.positions(
    from: csv,
    mapping: .defaultPositionsHeader,
    asOf: fixedDate
  )
  #expect(positions.count == 1)
  let aapl = try #require(positions.first)
  #expect(aapl.accountID == AccountID(rawValue: "Brokerage, Joint"))
  #expect(aapl.marketValue.amount == Decimal(string: "18000.00"))
}

// MARK: - Parser: balances

@Test func parsesHeaderBasedBalances() throws {
  let parser = CSVPortfolioParser(fallbackAccountID: AccountID(rawValue: "fallback"))
  let csv = """
  account,total,cash,buyingPower
  IRA-1,25000.00,5000.00,10000.00
  TAXABLE,100.50,100.50,
  """
  let balances = parser.balances(from: csv, asOf: fixedDate)

  #expect(balances.count == 2)

  let ira = try #require(balances[AccountID(rawValue: "IRA-1")])
  #expect(ira.total.amount == Decimal(string: "25000.00"))
  #expect(ira.cash.amount == Decimal(string: "5000.00"))
  #expect(ira.buyingPower?.amount == Decimal(string: "10000.00"))

  let taxable = try #require(balances[AccountID(rawValue: "TAXABLE")])
  #expect(taxable.buyingPower == nil)
}

@Test func customPositionalBalancesMapping() throws {
  let parser = CSVPortfolioParser(fallbackAccountID: AccountID(rawValue: "fallback"))
  // total, cash only, headerless, no account column -> fallback account.
  let mapping = ColumnMapping(
    hasHeaderRow: false,
    columns: [.total: .positional(0), .cash: .positional(1)]
  )
  let csv = "12345.67,1000.00"
  let balances = parser.balances(from: csv, mapping: mapping, asOf: fixedDate)

  let balance = try #require(balances[AccountID(rawValue: "fallback")])
  #expect(balance.total.amount == Decimal(string: "12345.67"))
  #expect(balance.cash.amount == Decimal(string: "1000.00"))
  #expect(balance.buyingPower == nil)
}

// MARK: - Provider conformance

@Test func providerIdentityAndCapabilities() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let provider = await CSVImportProvider(
    directory: dir,
    watchDirectory: false,
    now: fixedClock
  )
  #expect(provider.id == ProviderID(rawValue: "csv"))
  #expect(provider.displayName == "CSV Import")
  #expect(provider.capabilities == [.positions, .balances])
}

@Test func providerAuthenticationIsTrivial() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let provider = await CSVImportProvider(directory: dir, watchDirectory: false, now: fixedClock)

  let status = await provider.authenticationStatus()
  guard case .connected = status else {
    Issue.record("Expected connected status, got \(status)")
    return
  }
  // authenticate returns a complete session; signOut is a no-op.
  _ = try await provider.authenticate()
  try await provider.signOut()
}

@Test func providerReadsPositionsBalancesAndAccounts() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }

  try write("AMD,12,490.70\nNVDA,5,1200.00\n", to: dir.appendingPathComponent("positions.csv"))
  try write(
    "account,total,cash,buyingPower\ncsv,7000.00,100.00,200.00\n",
    to: dir.appendingPathComponent("balances.csv")
  )

  let provider = await CSVImportProvider(directory: dir, watchDirectory: false, now: fixedClock)

  let accounts = try await provider.listAccounts()
  #expect(accounts.map(\.id.rawValue) == ["csv"])

  let positions = try await provider.positions(for: AccountID(rawValue: "csv"))
  #expect(positions.count == 2)

  let balance = try await provider.balance(for: AccountID(rawValue: "csv"))
  #expect(balance.total.amount == Decimal(string: "7000.00"))
}

@Test func quoteAndPriceHistoryAreUnsupported() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let provider = await CSVImportProvider(directory: dir, watchDirectory: false, now: fixedClock)

  await #expect(throws: BrokerageError.self) {
    _ = try await provider.quote(for: Symbol(rawValue: "AMD"))
  }
  await #expect(throws: BrokerageError.self) {
    _ = try await provider.priceHistory(symbol: Symbol(rawValue: "AMD"), range: .oneMonth)
  }
}

@Test func unsupportedMethodNamesAreReported() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let provider = await CSVImportProvider(directory: dir, watchDirectory: false, now: fixedClock)

  do {
    _ = try await provider.quote(for: Symbol(rawValue: "AMD"))
    Issue.record("Expected quote to throw")
  } catch let error as BrokerageError {
    guard case .unsupported(let method) = error else {
      Issue.record("Expected .unsupported, got \(error)")
      return
    }
    #expect(method == "quote(for:)")
  }
}

// MARK: - Reload

@Test func reloadReflectsFileChanges() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }

  let positionsURL = dir.appendingPathComponent("positions.csv")
  try write("AMD,12,490.70\n", to: positionsURL)

  // Watcher disabled so the test drives reload() directly and deterministically.
  // The DirectoryWatcher's callback simply calls this same reload() method, so
  // this exercises the exact reload logic FSEvents would trigger.
  let provider = await CSVImportProvider(directory: dir, watchDirectory: false, now: fixedClock)

  var positions = try await provider.positions(for: AccountID(rawValue: "csv"))
  #expect(positions.count == 1)

  // Mutate the file, then reload.
  try write("AMD,12,490.70\nNVDA,5,1200.00\nTSLA,3,250.00\n", to: positionsURL)
  await provider.reload()

  positions = try await provider.positions(for: AccountID(rawValue: "csv"))
  #expect(positions.count == 3)
  #expect(Set(positions.map(\.symbol.rawValue)) == ["AMD", "NVDA", "TSLA"])
}

@Test func reloadHandlesMissingFiles() async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }

  // No files present -> empty, no throw.
  let provider = await CSVImportProvider(directory: dir, watchDirectory: false, now: fixedClock)
  let accounts = try await provider.listAccounts()
  #expect(accounts.isEmpty)

  await #expect(throws: BrokerageError.self) {
    _ = try await provider.balance(for: AccountID(rawValue: "csv"))
  }
}
