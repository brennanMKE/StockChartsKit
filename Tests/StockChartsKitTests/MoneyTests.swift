import Foundation
import Testing

@testable import StockChartsKit

@Suite("Money")
struct MoneyTests {
  @Test("CurrencyCode uppercases its raw value")
  func currencyCodeUppercases() {
    #expect(CurrencyCode(rawValue: "usd") == .usd)
    #expect(CurrencyCode(rawValue: "btc").rawValue == "BTC")
  }

  @Test("zero is the additive identity")
  func zeroIdentity() throws {
    let m = Money.usd(123.45)
    #expect(try (m + .zero) == m)
    #expect(try (.zero + m) == m)
    #expect(Money.zero.amount == 0)
    #expect(Money.zero.currency == .usd)
  }

  @Test(
    "addition and subtraction in the same currency",
    arguments: [
      (Decimal(1), Decimal(2)),
      (Decimal(string: "0.1")!, Decimal(string: "0.2")!),
      (Decimal(-5), Decimal(string: "12.34")!),
    ]
  )
  func sameCurrencyArithmetic(a: Decimal, b: Decimal) throws {
    let lhs = Money.usd(a)
    let rhs = Money.usd(b)
    #expect(try (lhs + rhs).amount == a + b)
    #expect(try (lhs - rhs).amount == a - b)
  }

  @Test("currency mismatch throws on +")
  func mismatchThrowsOnAdd() {
    let usd = Money.usd(1)
    let eur = Money(1, CurrencyCode(rawValue: "EUR"))
    #expect(throws: BrokerageError.self) {
      _ = try usd + eur
    }
  }

  @Test("currency mismatch throws on -")
  func mismatchThrowsOnSubtract() {
    let usd = Money.usd(1)
    let btc = Money(1, CurrencyCode(rawValue: "BTC"))
    #expect(throws: BrokerageError.self) {
      _ = try usd - btc
    }
  }

  @Test("multiplication preserves full decimal precision")
  func multiplicationPreservesPrecision() {
    // 0.1 has no exact Double representation; Decimal keeps it exact.
    let m = Money.usd(Decimal(string: "0.1")!)
    let product = m * Decimal(string: "0.3")!
    #expect(product.amount == Decimal(string: "0.03")!)
    #expect(product.currency == .usd)

    let big = Money.usd(Decimal(string: "12345.6789")!)
    let scaled = big * 3
    #expect(scaled.amount == Decimal(string: "37037.0367")!)
  }

  @Test("equality and hashing are on the exact stored decimal")
  func equalityOnExactDecimal() {
    #expect(Money.usd(Decimal(string: "1.0")!) == Money.usd(Decimal(string: "1.00")!))
    #expect(Money.usd(1) != Money.usd(Decimal(string: "1.0000001")!))
    #expect(Money.usd(1) != Money(1, CurrencyCode(rawValue: "EUR")))

    var set: Set<Money> = []
    set.insert(.usd(1))
    set.insert(.usd(1))
    #expect(set.count == 1)
  }

  @Test("Codable round-trip preserves amount and currency")
  func codableRoundTrip() throws {
    let original = Money(Decimal(string: "9876.54321")!, CurrencyCode(rawValue: "ETH"))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Money.self, from: data)
    #expect(decoded == original)
    #expect(decoded.amount == original.amount)
    #expect(decoded.currency.rawValue == "ETH")
  }
}
