import Foundation
import StockChartsKit

// MARK: - Accounts

/// One element of `GET /trader/v1/accounts`.
///
/// Schwab wraps each account under a `securitiesAccount` object. The
/// `hashValue` field on the *account-numbers* endpoint is the opaque,
/// URL-safe key used in per-account paths; the `accountNumber` is the
/// human-facing number. See ``SchwabProvider`` for how the two are mapped.
struct SchwabAccountEnvelope: Decodable, Sendable {
  let securitiesAccount: SchwabSecuritiesAccount
}

/// The account body Schwab returns under `securitiesAccount`.
struct SchwabSecuritiesAccount: Decodable, Sendable {
  /// The account type, e.g. `"CASH"`, `"MARGIN"`.
  let type: String?
  /// The human-facing account number.
  let accountNumber: String
  /// The positions, present only when `?fields=positions` is requested.
  let positions: [SchwabPosition]?
  /// The current balances block.
  let currentBalances: SchwabBalances?
}

/// One row of `GET /trader/v1/accounts/accountNumbers`, mapping the visible
/// account number to its hashed key used in per-account request paths.
struct SchwabAccountNumberMapping: Decodable, Sendable {
  let accountNumber: String
  let hashValue: String
}

// MARK: - Positions

/// A single Schwab position under `securitiesAccount.positions`.
///
/// Money/quantity fields decode through ``LossyDecimal`` so they accept both
/// JSON numbers and numeric strings with full `Decimal` precision.
struct SchwabPosition: Decodable, Sendable {
  let instrument: SchwabInstrument
  /// Long quantity; Schwab also reports `shortQuantity` separately.
  private let longQuantityValue: LossyDecimal?
  private let shortQuantityValue: LossyDecimal?
  private let averagePriceValue: LossyDecimal?
  private let marketValueValue: LossyDecimal?
  private let longOpenProfitLossValue: LossyDecimal?

  var longQuantity: Decimal? { longQuantityValue?.wrappedValue }
  var shortQuantity: Decimal? { shortQuantityValue?.wrappedValue }
  var averagePrice: Decimal? { averagePriceValue?.wrappedValue }
  var marketValue: Decimal? { marketValueValue?.wrappedValue }
  var longOpenProfitLoss: Decimal? { longOpenProfitLossValue?.wrappedValue }

  private enum CodingKeys: String, CodingKey {
    case instrument
    case longQuantityValue = "longQuantity"
    case shortQuantityValue = "shortQuantity"
    case averagePriceValue = "averagePrice"
    case marketValueValue = "marketValue"
    case longOpenProfitLossValue = "longOpenProfitLoss"
  }
}

/// The instrument a position references.
struct SchwabInstrument: Decodable, Sendable {
  let symbol: String
  /// e.g. `"EQUITY"`, `"ETF"`, `"MUTUAL_FUND"`, `"OPTION"`, `"FIXED_INCOME"`.
  let assetType: String?
}

// MARK: - Balances

/// The `currentBalances` block on a securities account.
struct SchwabBalances: Decodable, Sendable {
  private let liquidationValueValue: LossyDecimal?
  private let cashBalanceValue: LossyDecimal?
  private let totalCashValue: LossyDecimal?
  private let availableFundsValue: LossyDecimal?
  private let buyingPowerValue: LossyDecimal?

  var liquidationValue: Decimal? { liquidationValueValue?.wrappedValue }
  var cashBalance: Decimal? { cashBalanceValue?.wrappedValue }
  var totalCash: Decimal? { totalCashValue?.wrappedValue }
  var availableFunds: Decimal? { availableFundsValue?.wrappedValue }
  var buyingPower: Decimal? { buyingPowerValue?.wrappedValue }

  private enum CodingKeys: String, CodingKey {
    case liquidationValueValue = "liquidationValue"
    case cashBalanceValue = "cashBalance"
    case totalCashValue = "totalCash"
    case availableFundsValue = "availableFunds"
    case buyingPowerValue = "buyingPower"
  }
}

// MARK: - Quotes

/// One quote entry from `GET /marketdata/v1/quotes`. Schwab keys the response
/// object by symbol; each value carries a `quote` sub-object.
struct SchwabQuoteEntry: Decodable, Sendable {
  let symbol: String?
  let quote: SchwabQuoteFields?
}

/// The price fields within a quote entry.
struct SchwabQuoteFields: Decodable, Sendable {
  private let lastPriceValue: LossyDecimal?
  private let closePriceValue: LossyDecimal?
  /// Schwab quote timestamp in epoch milliseconds.
  let quoteTime: Double?

  var lastPrice: Decimal? { lastPriceValue?.wrappedValue }
  var closePrice: Decimal? { closePriceValue?.wrappedValue }

  private enum CodingKeys: String, CodingKey {
    case lastPriceValue = "lastPrice"
    case closePriceValue = "closePrice"
    case quoteTime
  }
}

// MARK: - Price history

/// The `GET /marketdata/v1/pricehistory` envelope.
struct SchwabPriceHistory: Decodable, Sendable {
  let candles: [SchwabCandle]
  let symbol: String?
  let empty: Bool?
}

/// One OHLCV candle. `datetime` is epoch milliseconds.
struct SchwabCandle: Decodable, Sendable {
  private let openValue: LossyDecimal?
  private let highValue: LossyDecimal?
  private let lowValue: LossyDecimal?
  private let closeValue: LossyDecimal?
  private let volumeValue: LossyDecimal?
  let datetime: Double?

  var open: Decimal? { openValue?.wrappedValue }
  var high: Decimal? { highValue?.wrappedValue }
  var low: Decimal? { lowValue?.wrappedValue }
  var close: Decimal? { closeValue?.wrappedValue }
  var volume: Decimal? { volumeValue?.wrappedValue }

  private enum CodingKeys: String, CodingKey {
    case openValue = "open"
    case highValue = "high"
    case lowValue = "low"
    case closeValue = "close"
    case volumeValue = "volume"
    case datetime
  }
}
