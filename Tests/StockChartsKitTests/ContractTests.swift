import Foundation
import Testing

@testable import StockChartsKit

@Suite("Capabilities OptionSet")
struct CapabilitiesTests {
  @Test("membership reflects inserted options")
  func membership() {
    let caps: Capabilities = [.positions, .balances, .quotes]
    #expect(caps.contains(.positions))
    #expect(caps.contains(.balances))
    #expect(caps.contains(.quotes))
    #expect(!caps.contains(.nativePriceHistory))
    #expect(!caps.contains(.crypto))
  }

  @Test("union and intersection behave as a set")
  func unionIntersection() {
    let a: Capabilities = [.positions, .balances]
    let b: Capabilities = [.balances, .quotes]
    #expect(a.union(b) == [.positions, .balances, .quotes])
    #expect(a.intersection(b) == [.balances])
  }

  @Test("raw values match the documented bit positions")
  func rawValues() {
    #expect(Capabilities.positions.rawValue == 1 << 0)
    #expect(Capabilities.balances.rawValue == 1 << 1)
    #expect(Capabilities.quotes.rawValue == 1 << 2)
    #expect(Capabilities.nativePriceHistory.rawValue == 1 << 3)
    #expect(Capabilities.nativePortfolioHistory.rawValue == 1 << 4)
    #expect(Capabilities.crypto.rawValue == 1 << 5)
    #expect(Capabilities.realtimeStreaming.rawValue == 1 << 6)
  }

  @Test("Codable round-trips on the raw value")
  func codableRoundTrip() throws {
    let caps: Capabilities = [.positions, .nativePriceHistory, .crypto]
    let data = try JSONEncoder().encode(caps)
    let decoded = try JSONDecoder().decode(Capabilities.self, from: data)
    #expect(decoded == caps)
    #expect(decoded.rawValue == caps.rawValue)
  }
}

@Suite("Configuration secrets")
struct ConfigurationTests {
  @Test("requiredSecret returns a present value")
  func presentValue() throws {
    let config = Configuration(secrets: ["consumerKey": "abc"])
    #expect(try config.requiredSecret("consumerKey") == "abc")
  }

  @Test("requiredSecret throws on a missing key")
  func missingKey() {
    let config = Configuration(secrets: [:])
    #expect(throws: BrokerageError.self) {
      try config.requiredSecret("consumerKey")
    }
  }
}

@Suite("AuthenticationStatus cases")
struct AuthenticationStatusTests {
  @Test("each case can be constructed")
  func constructEachCase() {
    let connected = AuthenticationStatus.connected(connectionID: ConnectionID(rawValue: "c1"))
    if case .connected(let id) = connected {
      #expect(id == ConnectionID(rawValue: "c1"))
    } else {
      Issue.record("expected .connected")
    }

    let url = URL(string: "https://example.com/portal")!
    let challenge = AuthenticationStatus.requiresChallenge(.hostedPortal(url: url))
    if case .requiresChallenge(.hostedPortal(let u)) = challenge {
      #expect(u == url)
    } else {
      Issue.record("expected .requiresChallenge(.hostedPortal)")
    }

    let errored = AuthenticationStatus.error(.notAuthenticated)
    if case .error(.notAuthenticated) = errored {
      // ok
    } else {
      Issue.record("expected .error(.notAuthenticated)")
    }
  }
}

@Suite("AuthChallenge cases")
struct AuthChallengeTests {
  @Test("each challenge case can be constructed")
  func constructEachCase() {
    let url = URL(string: "https://example.com/authorize")!
    _ = AuthChallenge.oauthRedirect(authorizationURL: url, callbackScheme: "myapp")
    _ = AuthChallenge.pinCode(authorizationURL: url)
    _ = AuthChallenge.mfaPushNotification(prompt: "Approve in your app")
    _ = AuthChallenge.hostedPortal(url: url)
  }
}

@Suite("KeychainStore round-trip")
struct KeychainStoreTests {
  /// Status codes that indicate the sandbox lacks Keychain access (no
  /// entitlement / no host bundle), which is expected under `swift test`.
  private func isSandboxUnavailable(_ error: BrokerageError) -> Bool {
    guard case .providerError(_, let statusCode, _) = error else { return false }
    guard let status = statusCode.map({ OSStatus($0) }) else { return false }
    // -34018 errSecMissingEntitlement, -25291 errSecNotAvailable,
    // -25308 errSecInteractionNotAllowed, -34018/-25300 variants.
    let unavailable: Set<OSStatus> = [
      errSecMissingEntitlement,
      errSecNotAvailable,
      errSecInteractionNotAllowed,
      errSecAuthFailed,
      errSecParam,
    ]
    return unavailable.contains(status)
  }

  @Test("set, read, then delete a secret")
  func roundTrip() async throws {
    let store = KeychainStore(service: "co.sstools.stockchartskit.tests")
    let key = "test.\(UUID().uuidString)"
    let value = "s3cr3t-\(UUID().uuidString)"

    do {
      try await store.set(value, for: key)
    } catch let error as BrokerageError where isSandboxUnavailable(error) {
      // Keychain is not available in this sandbox; skip rather than fail.
      withKnownIssue("Keychain unavailable in test sandbox") {
        Issue.record("Keychain set failed: \(error)")
      }
      return
    }

    do {
      let read = try await store.secret(key)
      #expect(read == value)
      try await store.delete(key)
      // After delete, reading should report no session.
      await #expect(throws: BrokerageError.self) {
        _ = try await store.secret(key)
      }
    } catch {
      // Best-effort cleanup, then rethrow.
      try? await store.delete(key)
      throw error
    }
  }
}
