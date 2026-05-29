import Foundation
import os

/// Watches a directory for changes and invokes a callback when it mutates.
///
/// Backed by a `DispatchSource` vnode monitor on the directory's file
/// descriptor, which fires on writes, renames, deletes, and attribute changes
/// within the directory. The handler is debounced trivially by the OS coalescing
/// vnode events; consumers should treat each callback as "something changed,
/// reload".
///
/// The watcher is a `final class` holding only `Sendable` state (an immutable
/// URL, an OS dispatch source, and a `@Sendable` handler), so it is safe to hold
/// from an actor. It stops watching on ``cancel()`` or deinitialisation.
///
/// FSEvents timing is asynchronous and non-deterministic, so the reload logic it
/// drives is structured to be callable directly (see ``CSVImportProvider``'s
/// `reload()`); this type only translates filesystem notifications into those
/// calls.
final class DirectoryWatcher: @unchecked Sendable {
  private static let log = Logger(
    subsystem: "co.sstools.stockchartskit",
    category: "csv"
  )

  private let url: URL
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var source: (any DispatchSourceFileSystemObject)?
  private var fileDescriptor: Int32 = -1

  /// Creates a watcher for `url` and begins monitoring immediately.
  ///
  /// - Parameters:
  ///   - url: The directory to watch.
  ///   - onChange: Invoked off the main thread whenever the directory mutates.
  ///     If the directory cannot be opened the watcher silently does nothing
  ///     (the provider still works via explicit `reload()`).
  init?(url: URL, onChange: @escaping @Sendable () -> Void) {
    self.url = url
    self.queue = DispatchQueue(label: "co.sstools.stockchartskit.csv.watcher")

    let descriptor = open(url.path, O_EVTONLY)
    guard descriptor >= 0 else {
      Self.log.warning("Could not open directory for watching; reloads must be explicit")
      return nil
    }
    self.fileDescriptor = descriptor

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete, .attrib],
      queue: queue
    )
    source.setEventHandler {
      onChange()
    }
    let fd = descriptor
    source.setCancelHandler {
      close(fd)
    }
    self.source = source
    source.resume()
  }

  /// Stops monitoring and releases the underlying file descriptor.
  ///
  /// Safe to call more than once.
  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    source?.cancel()
    source = nil
    fileDescriptor = -1
  }

  deinit {
    source?.cancel()
  }
}
