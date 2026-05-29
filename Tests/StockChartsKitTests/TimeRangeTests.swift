import Foundation
import Testing

@testable import StockChartsKit

@Suite("TimeRange")
struct TimeRangeTests {
  /// A Gregorian calendar pinned to US Eastern for deterministic DST tests.
  private var easternCalendar: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal
  }

  /// A UTC calendar for boundary math without DST influence.
  private var utcCalendar: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
  }

  private func date(_ iso: String, _ calendar: Calendar) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = calendar.timeZone
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = formatter.date(from: iso) { return d }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
  }

  @Test("raw values match the Robinhood selector exactly")
  func rawValues() {
    #expect(TimeRange.oneDay.rawValue == "1D")
    #expect(TimeRange.oneWeek.rawValue == "1W")
    #expect(TimeRange.oneMonth.rawValue == "1M")
    #expect(TimeRange.threeMonths.rawValue == "3M")
    #expect(TimeRange.yearToDate.rawValue == "YTD")
    #expect(TimeRange.oneYear.rawValue == "1Y")
    #expect(TimeRange.fiveYears.rawValue == "5Y")
    #expect(TimeRange.max.rawValue == "MAX")
    #expect(TimeRange.allCases.count == 8)
  }

  @Test("max returns distantPast as its start")
  func maxStartIsDistantPast() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let interval = TimeRange.max.interval(now: now)
    #expect(interval.start == .distantPast)
    #expect(interval.end == now)
  }

  @Test("YTD anchors at Jan 1 across different years", arguments: [2023, 2024, 2025, 2026])
  func ytdAnchorsAtJanuaryFirst(year: Int) {
    let cal = utcCalendar
    let now = date("\(year)-07-15T12:34:56Z", cal)
    let interval = TimeRange.yearToDate.interval(now: now, calendar: cal)
    let components = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: interval.start)
    #expect(components.year == year)
    #expect(components.month == 1)
    #expect(components.day == 1)
    #expect(components.hour == 0)
    #expect(components.minute == 0)
    #expect(components.second == 0)
  }

  @Test("one-day interval rolls over a spring-forward DST transition")
  func oneDayAcrossDST() {
    let cal = easternCalendar
    // US DST spring-forward 2024 was 2024-03-10 02:00 local.
    let now = date("2024-03-10T18:00:00Z", cal)
    let interval = TimeRange.oneDay.interval(now: now, calendar: cal)
    // Calendar-aware subtraction lands one calendar day earlier, not exactly
    // 86400 seconds, because the day spanned a 23-hour DST day.
    let expectedStart = cal.date(byAdding: .day, value: -1, to: now)!
    #expect(interval.start == expectedStart)
    #expect(interval.end == now)
    // The interval is shorter than a flat 24h due to the lost hour.
    #expect(interval.duration < 24 * 3600)
  }

  @Test("one-year interval crosses a year boundary")
  func oneYearAcrossYearBoundary() {
    let cal = utcCalendar
    let now = date("2025-01-15T00:00:00Z", cal)
    let interval = TimeRange.oneYear.interval(now: now, calendar: cal)
    let comps = cal.dateComponents([.year, .month, .day], from: interval.start)
    #expect(comps.year == 2024)
    #expect(comps.month == 1)
    #expect(comps.day == 15)
  }

  @Test("one-year interval handles the leap day correctly")
  func oneYearFromLeapDay() {
    let cal = utcCalendar
    // From 2025-02-28 back one year lands on 2024-02-28 (2024 is a leap year).
    let now = date("2025-02-28T00:00:00Z", cal)
    let interval = TimeRange.oneYear.interval(now: now, calendar: cal)
    let comps = cal.dateComponents([.year, .month, .day], from: interval.start)
    #expect(comps.year == 2024)
    #expect(comps.month == 2)
    #expect(comps.day == 28)
  }

  @Test("one-month interval back from leap day lands in February")
  func oneMonthIntoLeapFebruary() {
    let cal = utcCalendar
    // 2024-03-29 minus one month -> 2024-02-29 (leap day exists).
    let now = date("2024-03-29T00:00:00Z", cal)
    let interval = TimeRange.oneMonth.interval(now: now, calendar: cal)
    let comps = cal.dateComponents([.year, .month, .day], from: interval.start)
    #expect(comps.year == 2024)
    #expect(comps.month == 2)
    #expect(comps.day == 29)
  }

  @Test("granularity hints match the range")
  func granularityHints() {
    #expect(TimeRange.oneDay.granularity == .oneMinute)
    #expect(TimeRange.oneMonth.granularity == .oneDay)
    #expect(TimeRange.threeMonths.granularity == .oneDay)
    #expect(TimeRange.fiveYears.granularity == .oneWeek)
    #expect(TimeRange.max.granularity == .oneWeek)
  }

  @Test("TimeRange and Granularity round-trip through Codable")
  func codableRoundTrip() throws {
    for range in TimeRange.allCases {
      let data = try JSONEncoder().encode(range)
      #expect(try JSONDecoder().decode(TimeRange.self, from: data) == range)
    }
    let g = Granularity.fifteenMinutes
    let data = try JSONEncoder().encode(g)
    #expect(try JSONDecoder().decode(Granularity.self, from: data) == g)
  }
}
