import Foundation
import StockChartsKit
import os

/// Parses brokerage position and balance data out of CSV documents.
///
/// `CSVPortfolioParser` is a pure value type with no I/O and no watcher, so the
/// parsing logic is exercised in isolation by tests. The ``CSVImportProvider``
/// composes it with file loading and directory watching.
///
/// ## Supported schema
///
/// **Positions.** Each data row describes one holding. Required fields are
/// ``ColumnMapping/Field/symbol`` and ``ColumnMapping/Field/quantity`` plus
/// either ``ColumnMapping/Field/marketValue`` or
/// ``ColumnMapping/Field/price`` (market value is derived as
/// `quantity × price` when only the price is present). The
/// ``ColumnMapping/Field/account`` column is optional; rows without one are
/// attributed to the provider's fallback account.
///
/// **Balances.** Each data row describes one account's balance. Required fields
/// are ``ColumnMapping/Field/total`` and ``ColumnMapping/Field/cash``.
///
/// Malformed rows (missing required columns, undecodable decimals) are skipped
/// with a logged warning; the parser never throws on bad rows and never crashes
/// on ragged input.
public struct CSVPortfolioParser: Sendable {
  private static let log = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "csv"
  )

  /// The base currency to stamp on parsed money values.
  public let currency: CurrencyCode

  /// The account identifier to attribute rows that carry no account column.
  public let fallbackAccountID: AccountID

  /// Creates a parser.
  ///
  /// - Parameters:
  ///   - currency: The base currency for parsed money. Defaults to USD.
  ///   - fallbackAccountID: The account used for rows lacking an account
  ///     column.
  public init(
    currency: CurrencyCode = .usd,
    fallbackAccountID: AccountID
  ) {
    self.currency = currency
    self.fallbackAccountID = fallbackAccountID
  }

  // MARK: Positions

  /// Parses positions from CSV text using the given column mapping.
  ///
  /// - Parameters:
  ///   - text: The full positions CSV document.
  ///   - mapping: How to resolve each field to a column.
  ///   - asOf: The timestamp to stamp on each parsed position.
  /// - Returns: The successfully parsed positions, in document order.
  public func positions(
    from text: String,
    mapping: ColumnMapping = .defaultPositionsPositional,
    asOf: Date
  ) -> [Position] {
    let rows = CSVParsing.rows(from: text)
    guard !rows.isEmpty else { return [] }
    let resolver = ColumnResolver(mapping: mapping, headerRow: rows.first ?? [])
    let dataRows = mapping.hasHeaderRow ? Array(rows.dropFirst()) : rows

    var positions: [Position] = []
    for (offset, row) in dataRows.enumerated() {
      let lineNumber = offset + (mapping.hasHeaderRow ? 2 : 1)
      guard let position = self.position(from: row, resolver: resolver, asOf: asOf) else {
        Self.log.warning("Skipped malformed positions row at line \(lineNumber, privacy: .public)")
        continue
      }
      positions.append(position)
    }
    return positions
  }

  private func position(
    from row: [String],
    resolver: ColumnResolver,
    asOf: Date
  ) -> Position? {
    guard
      let symbolText = resolver.value(.symbol, in: row), !symbolText.isEmpty,
      let quantityText = resolver.value(.quantity, in: row),
      let quantity = Decimal(string: quantityText)
    else {
      return nil
    }

    let marketValue: Decimal
    if let mvText = resolver.value(.marketValue, in: row), let mv = Decimal(string: mvText) {
      marketValue = mv
    } else if let priceText = resolver.value(.price, in: row), let price = Decimal(string: priceText) {
      marketValue = quantity * price
    } else {
      return nil
    }

    let accountID: AccountID
    if let accountText = resolver.value(.account, in: row), !accountText.isEmpty {
      accountID = AccountID(rawValue: accountText)
    } else {
      accountID = self.fallbackAccountID
    }

    var averageCost: Money? = nil
    if let acText = resolver.value(.averageCost, in: row), let ac = Decimal(string: acText) {
      averageCost = Money(ac, self.currency)
    }

    let assetClass: AssetClass
    if
      let acText = resolver.value(.assetClass, in: row),
      let parsed = AssetClass(rawValue: acText)
    {
      assetClass = parsed
    } else {
      assetClass = .equity
    }

    return Position(
      accountID: accountID,
      symbol: Symbol(rawValue: symbolText),
      assetClass: assetClass,
      quantity: quantity,
      averageCost: averageCost,
      marketValue: Money(marketValue, self.currency),
      unrealizedPL: nil,
      asOf: asOf
    )
  }

  // MARK: Balances

  /// Parses balances keyed by account from CSV text.
  ///
  /// - Parameters:
  ///   - text: The full balances CSV document.
  ///   - mapping: How to resolve each field to a column.
  ///   - asOf: The timestamp to stamp on each parsed balance.
  /// - Returns: A dictionary of account identifier to its parsed balance.
  public func balances(
    from text: String,
    mapping: ColumnMapping = .defaultBalancesHeader,
    asOf: Date
  ) -> [AccountID: Balance] {
    let rows = CSVParsing.rows(from: text)
    guard !rows.isEmpty else { return [:] }
    let resolver = ColumnResolver(mapping: mapping, headerRow: rows.first ?? [])
    let dataRows = mapping.hasHeaderRow ? Array(rows.dropFirst()) : rows

    var balances: [AccountID: Balance] = [:]
    for (offset, row) in dataRows.enumerated() {
      let lineNumber = offset + (mapping.hasHeaderRow ? 2 : 1)
      guard let balance = self.balance(from: row, resolver: resolver, asOf: asOf) else {
        Self.log.warning("Skipped malformed balances row at line \(lineNumber, privacy: .public)")
        continue
      }
      balances[balance.accountID] = balance
    }
    return balances
  }

  private func balance(
    from row: [String],
    resolver: ColumnResolver,
    asOf: Date
  ) -> Balance? {
    guard
      let totalText = resolver.value(.total, in: row), let total = Decimal(string: totalText),
      let cashText = resolver.value(.cash, in: row), let cash = Decimal(string: cashText)
    else {
      return nil
    }

    let accountID: AccountID
    if let accountText = resolver.value(.account, in: row), !accountText.isEmpty {
      accountID = AccountID(rawValue: accountText)
    } else {
      accountID = self.fallbackAccountID
    }

    var buyingPower: Money? = nil
    if let bpText = resolver.value(.buyingPower, in: row), let bp = Decimal(string: bpText) {
      buyingPower = Money(bp, self.currency)
    }

    return Balance(
      accountID: accountID,
      total: Money(total, self.currency),
      cash: Money(cash, self.currency),
      buyingPower: buyingPower,
      asOf: asOf
    )
  }
}

/// Resolves ``ColumnMapping/Field`` values out of a single CSV row.
private struct ColumnResolver {
  private let indices: [ColumnMapping.Field: Int]

  init(mapping: ColumnMapping, headerRow: [String]) {
    var indices: [ColumnMapping.Field: Int] = [:]
    let normalizedHeaders = headerRow.map {
      $0.trimmingCharacters(in: .whitespaces).lowercased()
    }
    for (field, column) in mapping.columns {
      switch column {
      case .positional(let index):
        indices[field] = index
      case .header(let name):
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let index = normalizedHeaders.firstIndex(of: target) {
          indices[field] = index
        }
      }
    }
    self.indices = indices
  }

  /// Returns the raw value of `field` in `row`, or `nil` when the field is not
  /// mapped or the row is too short.
  func value(_ field: ColumnMapping.Field, in row: [String]) -> String? {
    guard let index = indices[field], index >= 0, index < row.count else { return nil }
    return row[index]
  }
}
