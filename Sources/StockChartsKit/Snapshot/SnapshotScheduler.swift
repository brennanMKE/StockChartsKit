import Foundation
import os

/// A small async helper that periodically records ``PortfolioSnapshot``s from a
/// set of ``BrokerageProvider``s into a ``SnapshotStore``.
///
/// Per PRD §7 the package ships this helper but does **not** manage launch
/// agents or background tasks — that is the host app's job. The host decides the
/// cadence (e.g. hourly while foregrounded, daily otherwise) and drives the
/// scheduler via ``start()`` / ``stop()`` (or runs a single pass with
/// ``recordOnce()``).
///
/// On each pass the scheduler walks every provider, lists its accounts, and for
/// each account fetches the current balance and positions and records a snapshot
/// whose `totalValue` is the balance's `total`. A single provider or account
/// failure does **not** abort the pass: the error is logged (never any secret)
/// and the remaining providers and accounts are still processed.
///
/// The scheduler is an `actor`, so its running task is isolated and cannot leak:
/// ``stop()`` cancels it cleanly and waits for it to finish. The sleep used
/// between passes and the snapshot timestamp source are injectable so tests run
/// deterministically without sleeping real time.
///
/// ## Example
/// ```swift
/// let scheduler = SnapshotScheduler(
///   providers: [etrade, coinbase],
///   store: snapshotStore,
///   interval: .seconds(3600)  // once an hour while foregrounded
/// )
///
/// // The host drives the lifecycle — e.g. start when the window becomes active.
/// await scheduler.start()
///
/// // ...and stops it when the app resigns active or before termination.
/// await scheduler.stop()
/// ```
public actor SnapshotScheduler {
  /// The providers polled on each pass.
  private let providers: [any BrokerageProvider]

  /// The store snapshots are recorded into.
  private let store: any SnapshotStore

  /// How long to sleep between passes.
  private let interval: Duration

  /// The injectable sleep, defaulting to `Task.sleep(for:)`. Tests inject a
  /// controlled implementation so the loop advances without real delay.
  private let sleep: @Sendable (Duration) async throws -> Void

  /// The injectable timestamp source, defaulting to `Date()`. Tests inject a
  /// fixed value for deterministic snapshot timestamps.
  private let now: @Sendable () -> Date

  /// The running loop task, or `nil` when stopped. Storing it makes it
  /// impossible to leak: ``stop()`` cancels and awaits it.
  private var task: Task<Void, Never>?

  private static let log = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "SnapshotScheduler"
  )

  /// Creates a scheduler.
  ///
  /// - Parameters:
  ///   - providers: The providers to snapshot on each pass.
  ///   - store: The store snapshots are recorded into.
  ///   - interval: How long to wait between passes once ``start()`` is running.
  ///   - sleep: The sleep used between passes; defaults to `Task.sleep(for:)`.
  ///     Inject a controlled implementation in tests to avoid real delays.
  ///   - now: The snapshot timestamp source; defaults to `Date()`. Inject a
  ///     fixed value in tests for deterministic timestamps.
  public init(
    providers: [any BrokerageProvider],
    store: any SnapshotStore,
    interval: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.providers = providers
    self.store = store
    self.interval = interval
    self.sleep = sleep
    self.now = now
  }

  /// Records exactly one pass over all providers and accounts.
  ///
  /// For each provider this lists accounts, then for each account fetches the
  /// balance and positions and records a ``PortfolioSnapshot``. A failure from
  /// any single provider or account is logged and skipped; the rest of the pass
  /// continues. This method never throws — partial failure is tolerated by
  /// design.
  public func recordOnce() async {
    for provider in providers {
      let providerID = provider.id
      let accounts: [Account]
      do {
        accounts = try await provider.listAccounts()
      } catch {
        Self.log.error(
          "listAccounts failed for provider \(providerID.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        continue
      }

      for account in accounts {
        await recordSnapshot(for: account, provider: provider)
      }
    }
  }

  /// Starts the periodic loop if it is not already running.
  ///
  /// The loop records a pass immediately, then sleeps ``interval`` and repeats
  /// until cancelled via ``stop()``. Calling ``start()`` while already running
  /// is a no-op.
  public func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      await self?.runLoop()
    }
  }

  /// Stops the loop, cancelling the running task and awaiting its completion.
  ///
  /// After this returns no further snapshots are recorded. Safe to call when not
  /// running.
  public func stop() async {
    task?.cancel()
    await task?.value
    task = nil
  }

  // MARK: Private

  /// The body of the running task: record, sleep, repeat until cancelled.
  private func runLoop() async {
    while !Task.isCancelled {
      await recordOnce()
      do {
        try await sleep(interval)
      } catch {
        // A thrown error here is cancellation (or an injected sleep failing);
        // either way, exit the loop cleanly.
        break
      }
    }
  }

  /// Records a single account's snapshot, logging and swallowing any failure.
  private func recordSnapshot(
    for account: Account,
    provider: any BrokerageProvider
  ) async {
    do {
      let balance = try await provider.balance(for: account.id)
      let positions = try await provider.positions(for: account.id)
      let snapshot = PortfolioSnapshot(
        accountID: account.id,
        timestamp: now(),
        totalValue: balance.total,
        positions: positions
      )
      try await store.recordSnapshot(snapshot)
    } catch {
      Self.log.error(
        "Snapshot failed for account \(account.id.rawValue, privacy: .public) on provider \(provider.id.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
