import Foundation
import Testing

import StockChartsKitTesting

@Suite("ReplayURLProtocol (offline)")
struct ReplayURLProtocolTests {
  /// A scheme/host that does not resolve, proving the response comes from the
  /// fixture and never from the network.
  private let baseURL = URL(string: "https://offline.invalid")!

  @Test("serves a canned fixture from the test bundle with no network")
  func servesFixtureFromBundle() async throws {
    let store = FixtureStore()
    try store.register(
      key: FixtureKey(method: "GET", path: "/v1/accounts"),
      fixtureNamed: "accounts",
      in: Bundle.module
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let url = baseURL.appendingPathComponent("v1/accounts")
    let (data, response) = try await session.data(from: url)

    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)

    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let accounts = json?["accounts"] as? [[String: Any]]
    #expect(accounts?.count == 1)
    #expect(accounts?.first?["id"] as? String == "acct-redacted-1")
    // The committed fixture must carry no live PII.
    #expect(accounts?.first?["displayName"] as? String == "Brokerage REDACTED")
  }

  @Test("serves an inline fixture value")
  func servesInlineFixture() async throws {
    let store = FixtureStore()
    let body = Data(#"{"ok":true}"#.utf8)
    store.register(
      key: FixtureKey(method: "GET", path: "/ping"),
      fixture: HTTPFixture(statusCode: 200, body: body)
    )
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    let (data, response) = try await session.data(
      from: baseURL.appendingPathComponent("ping")
    )
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(data == body)
  }

  @Test("an unrecorded request fails loudly instead of hitting the network")
  func unrecordedRequestFails() async throws {
    let store = FixtureStore()
    let session = ReplayURLProtocol.makeSession(store: store)
    defer { ReplayURLProtocol.deregister(session: session) }

    await #expect(throws: (any Error).self) {
      _ = try await session.data(from: baseURL.appendingPathComponent("missing"))
    }
  }
}
