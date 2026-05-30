import Foundation
import Testing

@testable import StockChartsKit
import StockChartsKitTesting

@Suite("SnapshotScheduler")
struct SnapshotSchedulerTests {
  private let providerA = ProviderID(rawValue: "alpha")
  private let providerB = ProviderID(rawValue: "beta")

  /// A fixed timestamp source for deterministic snapshot timestamps.
  private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

  private func account(_ raw: String, provider: ProviderID) -> Account {
    Account(
      id: AccountID(rawValue: raw),
      providerID: provider,
      displayName: "Account \(raw)",
      kind: .brokerage,
      baseCurrency: .usd,
      connectionID: nil
    )
  }

  private func balance(_ account: Account, total: Decimal) -> Balance {
    Balance(
      accountID: account.id,
      total: Money(total, .usd),
      cash: Money(0, .usd),
      buyingPower: nil,
      asOf: fixedDate
    )
  }

  private func position(_ account: Account, symbol: String, marketValue: Decimal) -> Position {
    Position(
      accountID: account.id,
      symbol: Symbol(rawValue: symbol),
      assetClass: .equity,
      quantity: 1,
      averageCost: nil,
      marketValue: Money(marketValue, .usd),
      unrealizedPL: nil,
      asOf: fixedDate
    )
  }

  /// A controlled sleep whose completions are driven explicitly by the test, so
  /// the run loop advances pass-by-pass without sleeping real time.
  ///
  /// Crucially this sleep is **cancellation-aware** (like the real
  /// `Task.sleep(for:)`): a pending sleeper is resumed with a `CancellationError`
  /// when its task is cancelled, so the scheduler's loop can exit and
  /// `stop()`'s `await task.value` does not hang.
  private actor SleepGate {
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID = 0

    /// The sleep closure to inject — suspends until `release()` or cancellation.
    func sleep(_ duration: Duration) async throws {
      try Task.checkCancellation()
      let id = nextID
      nextID += 1
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          waiters.append((id, continuation))
        }
      } onCancel: {
        Task { await self.cancel(id: id) }
      }
    }

    /// Resumes the oldest pending sleeper. Spins briefly until a sleeper is
    /// registered so the test doesn't race the loop.
    func release() async {
      while waiters.isEmpty {
        await Task.yield()
      }
      let waiter = waiters.removeFirst()
      waiter.continuation.resume()
    }

    /// Resumes the oldest pending sleeper if one is already registered, doing
    /// nothing otherwise. Used to prove no new sleeper appears after `stop()`
    /// without spinning forever.
    func tryRelease() {
      guard !waiters.isEmpty else { return }
      waiters.removeFirst().continuation.resume()
    }

    /// Resumes the identified sleeper with a `CancellationError`, if still pending.
    private func cancel(id: Int) {
      guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
      let waiter = waiters.remove(at: index)
      waiter.continuation.resume(throwing: CancellationError())
    }

    /// Fails any pending sleepers (used to unstick on teardown).
    func cancelAll() {
      for waiter in waiters {
        waiter.continuation.resume(throwing: CancellationError())
      }
      waiters.removeAll()
    }
  }

  // MARK: recordOnce

  @Test("recordOnce records one snapshot per account with the balance total")
  func recordOnceRecordsPerAccount() async throws {
    let acct1 = account("a1", provider: providerA)
    let acct2 = account("a2", provider: providerA)
    let store = InMemorySnapshotStore()
    let provider = MockBrokerageProvider(id: providerA)
    await provider.setAccounts([acct1, acct2])
    await provider.setBalance { id in
      self.balance(self.account(id.rawValue, provider: self.providerA),
        total: id == acct1.id ? 1000 : 2500)
    }
    await provider.setPositions { id in
      id == acct1.id ? [self.position(acct1, symbol: "AAA", marketValue: 1000)] : []
    }

    let scheduler = SnapshotScheduler(
      providers: [provider],
      store: store,
      interval: .seconds(60),
      sleep: { _ in },
      now: { self.fixedDate }
    )
    await scheduler.recordOnce()

    let all = try await store.snapshots(
      providerID: nil,
      in: DateInterval(start: .distantPast, end: .distantFuture)
    )
    #expect(all.count == 2)

    let s1 = try #require(all.first { $0.accountID == acct1.id })
    #expect(s1.totalValue == Money(1000, .usd))
    #expect(s1.timestamp == fixedDate)
    #expect(s1.positions.count == 1)

    let s2 = try #require(all.first { $0.accountID == acct2.id })
    #expect(s2.totalValue == Money(2500, .usd))
    #expect(s2.positions.isEmpty)
  }

  // MARK: partial-failure resilience

  @Test("a failing provider does not prevent other providers' snapshots")
  func partialFailureIsTolerated() async throws {
    let good = account("good", provider: providerB)
    let store = InMemorySnapshotStore()

    let failing = MockBrokerageProvider(id: providerA)
    await failing.setListAccounts {
      throw BrokerageError.rateLimited(retryAfter: nil)
    }

    let working = MockBrokerageProvider(id: providerB)
    await working.setAccounts([good])
    await working.setBalance { _ in self.balance(good, total: 4200) }

    let scheduler = SnapshotScheduler(
      providers: [failing, working],
      store: store,
      interval: .seconds(60),
      sleep: { _ in },
      now: { self.fixedDate }
    )
    await scheduler.recordOnce()

    let all = try await store.snapshots(
      providerID: nil,
      in: DateInterval(start: .distantPast, end: .distantFuture)
    )
    #expect(all.count == 1)
    #expect(all.first?.accountID == good.id)
    #expect(all.first?.totalValue == Money(4200, .usd))
  }

  @Test("a failing account does not prevent sibling accounts on the same provider")
  func failingAccountSkipped() async throws {
    let bad = account("bad", provider: providerA)
    let good = account("good", provider: providerA)
    let store = InMemorySnapshotStore()

    let provider = MockBrokerageProvider(id: providerA)
    await provider.setAccounts([bad, good])
    await provider.setBalance { id in
      if id == bad.id { throw BrokerageError.unsupported(method: "balance(for:)") }
      return self.balance(good, total: 777)
    }

    let scheduler = SnapshotScheduler(
      providers: [provider],
      store: store,
      interval: .seconds(60),
      sleep: { _ in },
      now: { self.fixedDate }
    )
    await scheduler.recordOnce()

    let all = try await store.snapshots(
      providerID: nil,
      in: DateInterval(start: .distantPast, end: .distantFuture)
    )
    #expect(all.count == 1)
    #expect(all.first?.accountID == good.id)
  }

  // MARK: run loop + cancellation

  @Test("the run loop records multiple passes and stop() halts it cleanly")
  func runLoopRecordsAndStops() async throws {
    let acct = account("a1", provider: providerA)
    let store = InMemorySnapshotStore()
    let provider = MockBrokerageProvider(id: providerA)
    await provider.setAccounts([acct])
    await provider.setBalance { _ in self.balance(acct, total: 100) }

    let gate = SleepGate()
    let scheduler = SnapshotScheduler(
      providers: [provider],
      store: store,
      interval: .seconds(60),
      sleep: { try await gate.sleep($0) },
      now: { self.fixedDate }
    )

    await scheduler.start()

    // Pass 1 runs immediately, then the loop suspends in sleep. Release twice to
    // let two more passes run. After each release the loop records another pass
    // and suspends again, so releasing implies the prior pass completed.
    await gate.release()  // -> pass 2 records, then suspends
    await gate.release()  // -> pass 3 records, then suspends

    // Stop while suspended in sleep: cancellation unblocks the continuation and
    // the loop exits. Assert stop() actually returns (does not hang).
    let stopped: Void? = await withTimeout(seconds: 5) {
      await scheduler.stop()
    }
    #expect(stopped != nil, "stop() must return without hanging")

    // Drain any sleeper left pending (defensive; loop should have exited).
    await gate.cancelAll()

    let countAfterStop = try await store.snapshots(
      providerID: nil,
      in: DateInterval(start: .distantPast, end: .distantFuture)
    ).count
    #expect(countAfterStop >= 3, "expected at least three recorded passes")

    // No further snapshots after stop: there is no pending sleeper to release,
    // and a stray release must not produce another pass.
    await gate.tryRelease()
    await Task.yield()
    let finalCount = try await store.snapshots(
      providerID: nil,
      in: DateInterval(start: .distantPast, end: .distantFuture)
    ).count
    #expect(finalCount == countAfterStop, "no snapshots may be recorded after stop()")
  }

  @Test("start() is idempotent and stop() is safe when not running")
  func startIdempotentStopSafe() async {
    let store = InMemorySnapshotStore()
    let provider = MockBrokerageProvider(id: providerA)
    let scheduler = SnapshotScheduler(
      providers: [provider],
      store: store,
      interval: .seconds(60),
      sleep: { _ in },
      now: { self.fixedDate }
    )
    // stop() before start() must not crash or hang.
    await scheduler.stop()
    await scheduler.start()
    await scheduler.start()  // no-op
    await scheduler.stop()
  }

  /// Runs `operation`, returning `nil` if it does not finish within `seconds`.
  private func withTimeout(
    seconds: Double,
    _ operation: @escaping @Sendable () async -> Void
  ) async -> Void? {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await operation()
        return true
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(seconds))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first ? () : nil
    }
  }
}
