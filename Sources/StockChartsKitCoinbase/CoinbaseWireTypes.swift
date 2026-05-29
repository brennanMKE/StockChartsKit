import Foundation
import StockChartsKit

// Wire types mirroring the Coinbase Advanced Trade API JSON shapes. The shared
// `HTTPClient` decoder uses `.convertFromSnakeCase`, so snake_case fields map to
// camelCase properties automatically; explicit `CodingKeys` are only used where
// the wire name does not follow that rule.

/// `GET /api/v3/brokerage/accounts` response envelope.
struct AccountsEnvelope: Decodable, Sendable {
  let accounts: [WireAccount]
}

/// A single account in the accounts list.
struct WireAccount: Decodable, Sendable {
  let uuid: String
  let name: String?
  let currency: String
  let availableBalance: WireMoney?
  let hold: WireMoney?
}

/// A `{ "value": "...", "currency": "..." }` money object.
struct WireMoney: Decodable, Sendable {
  @LossyDecimal var value: Decimal
  let currency: String
}

/// `GET /api/v3/brokerage/products/{id}/ticker` response envelope.
struct TickerEnvelope: Decodable, Sendable {
  let trades: [WireTrade]
}

/// A single recent trade from the ticker endpoint.
struct WireTrade: Decodable, Sendable {
  @LossyDecimal var price: Decimal
  let time: Date?
}

/// `GET /api/v3/brokerage/products/{id}/candles` response envelope.
struct CandlesEnvelope: Decodable, Sendable {
  let candles: [WireCandle]
}

/// A single OHLC candle. `start` is a Unix-epoch-seconds string.
struct WireCandle: Decodable, Sendable {
  let start: String
  @LossyDecimal var low: Decimal
  @LossyDecimal var high: Decimal
  @LossyDecimal var open: Decimal
  @LossyDecimal var close: Decimal

  /// The candle's start time parsed from the epoch-seconds string.
  var startDate: Date? {
    guard let seconds = TimeInterval(start) else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }
}
