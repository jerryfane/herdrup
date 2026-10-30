import Foundation
#if !os(Linux)
// Apple-only for the reason `ComposerUploader` gives: Linux's libswiftObservation does not
// link in the swift:6.1 image. The app's SwiftUI views observe `held`; the Linux tests do not.
import Observation
#endif

/// The owner's Gram file downloads, kept OUTSIDE the Gram page (#574).
///
/// The page used to own them, and that is why a download died on a tab switch: the open
/// ran in the page's task, `onDisappear` cancelled it, and the last caller out cancelled the
/// transfer. On iPhone Gram is a persistent tab whose `onDisappear` fires on every switch to
/// Agents; on iPad the page is rebuilt per section, taking its `@State` (the transfers and
/// the ring) with it. Either way the reader had to start again and stay on the page.
///
/// Here the PAGE only waits. A download the reader started (`start`, an open or a save)
/// runs until it lands in the download cache, fails, is cancelled by the reader (`cancel`),
/// or the session ends (`cancelAll`: disconnect and sign-out, whose epoch rule also refuses
/// a late store). The page joins it again when it comes back (`join`), so the ring is back
/// on the card and the file opens when it lands; a download that landed while the reader
/// was away is a cache hit, so tapping the file opens it at once.
///
/// - ONE TRANSFER PER ID, shared by everyone who wants that file: the image prefetch, an
///   open and a save. A prefetch (`fetch`) is the card's while it is on screen: its last
///   waiter leaving cancels it, unless the reader's own open or save has adopted it.
/// - ONE HELD DOWNLOAD at a time (`held`), as the page has always allowed: a second open or
///   save is refused while one runs, and only that download draws a ring.
/// - PROGRESS is the held download's only (`held.progress`), coalesced to whole percents
///   and never running backwards (`report`).
///
/// Platform-free, so its lifetime and cancellation are unit-tested on Linux; the transfer
/// itself (the wire call and the cache write) is the caller's `Transfer`.
@MainActor
public final class GramDownloadStore {
    public typealias Fetched = (name: String, mime: String, data: Data, cached: CachedGramFile?)
    /// Reports the bytes received so far, from whatever thread the transport calls on.
    public typealias Report = @Sendable (_ received: Int) -> Void
    /// Fetches a file, keeps it in the download cache, and returns it.
    public typealias Transfer = @MainActor (_ report: @escaping Report) async throws -> Fetched

    /// What the reader asked for when they started the download.
    public enum Purpose: Sendable, Equatable {
        case open
        case save
    }

    /// The reader's own download, drawn as a ring on its card until it ends.
    public struct Held: Equatable {
        public let id: String
        public let purpose: Purpose
        /// The reply's expected size, against which `progress` is measured; nil when unknown.
        public let expectedBytes: Int?
        /// Bytes received against bytes expected. Stays nil until the transport reports
        /// any: a mock or a local socket reports none, and a share nothing drives would pin
        /// a determinate ring at 0%, so the card's ring spins instead.
        public fileprivate(set) var progress: (received: Int, total: Int)?

        public static func == (lhs: Held, rhs: Held) -> Bool {
            lhs.id == rhs.id && lhs.purpose == rhs.purpose && lhs.expectedBytes == rhs.expectedBytes
                && lhs.progress?.received == rhs.progress?.received
                && lhs.progress?.total == rhs.progress?.total
        }
    }

    /// A held download that failed while no page waited on it (the reader was on Agents),
    /// kept for the page to report when it comes back.
    public struct Failure {
        public let id: String
        public let purpose: Purpose
        public let error: Error
    }

    /// The reader's running open or save, nil when none runs.
    public private(set) var held: Held? {
        get {
            observeHeld()
            return storedHeld
        }
        set {
            mutateHeld { storedHeld = newValue }
        }
    }
    private var storedHeld: Held?

    #if !os(Linux)
    private let registrar = ObservationRegistrar()

    private func observeHeld() {
        registrar.access(self, keyPath: \.held)
    }

    private func mutateHeld(_ change: () -> Void) {
        registrar.withMutation(of: self, keyPath: \.held, change)
    }
    #else
    private func observeHeld() {}
    private func mutateHeld(_ change: () -> Void) { change() }
    #endif

    @MainActor
    private final class Entry {
        var waiters: [UUID: CheckedContinuation<Fetched?, Error>] = [:]
        var task: Task<Void, Never>?
        /// The reader started or adopted it: it runs whether or not anyone waits.
        var kept = false
        /// The waiters that are a page's `join`, which reports a failure; a prefetch does not.
        var joined: Set<UUID> = []
    }

    private var entries: [String: Entry] = [:]
    /// The transfer `held` describes, so a finished or cancelled transfer clears only its
    /// own ring, never one a later open of the same file started.
    private var heldEntry: Entry?
    /// See `takeFailure`.
    private var unreported: Failure?

    public nonisolated init() {}

    /// Whether a transfer for `id` is running (started by anyone).
    public func isRunning(_ id: String) -> Bool { entries[id] != nil }

    /// Starts the reader's own download of `id`, or adopts the prefetch already running for
    /// it, and keeps it running until it ends on its own, `cancel` or `cancelAll`. False,
    /// starting nothing, while another held download runs. The caller waits with `join`.
    @discardableResult
    public func start(id: String, purpose: Purpose, expectedBytes: Int?, transfer: @escaping Transfer) -> Bool {
        guard storedHeld == nil else { return false }
        let entry = entries[id] ?? begin(id: id, transfer: transfer)
        entry.kept = true
        heldEntry = entry
        unreported = nil
        held = Held(id: id, purpose: purpose, expectedBytes: expectedBytes, progress: nil)
        return true
    }

    /// Waits on the transfer running for `id`, starting it with `transfer` if none is. A
    /// cancelled caller stops waiting at once (CancellationError); the transfer is cancelled
    /// when no caller is left waiting on it, unless the reader's open or save keeps it.
    public func fetch(id: String, transfer: @escaping Transfer) async throws -> Fetched {
        // Never nil: the transfer is started when none runs.
        guard let fetched = try await wait(id: id, starting: transfer) else { throw CancellationError() }
        return fetched
    }

    /// Waits on the transfer running for `id`; nil at once when none is (it has ended: its
    /// bytes are in the cache, or it failed). Leaving (the caller cancelled) never ends a
    /// held download.
    public func join(id: String) async throws -> Fetched? {
        try await wait(id: id, starting: nil)
    }

    /// The reader's explicit cancel: ends the transfer for `id` whoever waits on it. Every
    /// waiter gets CancellationError, and its ring goes.
    public func cancel(id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        end(entry, with: .failure(CancellationError()))
        entry.task?.cancel()
    }

    /// The session ended (disconnect, sign-out, another session): every transfer stops,
    /// and an unreported failure from that connection must not follow the reader into the next.
    public func cancelAll() {
        for id in Array(entries.keys) { cancel(id: id) }
        unreported = nil
    }

    // MARK: - Transfers

    private func wait(id: String, starting transfer: Transfer?) async throws -> Fetched? {
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Fetched?, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard let entry = entries[id] ?? transfer.map({ begin(id: id, transfer: $0) }) else {
                    continuation.resume(returning: nil)
                    return
                }
                entry.waiters[waiter] = continuation
                if transfer == nil { entry.joined.insert(waiter) }
            }
        } onCancel: {
            Task { @MainActor in self.leave(waiter, id: id) }
        }
    }

    private func begin(id: String, transfer: @escaping Transfer) -> Entry {
        let entry = Entry()
        entries[id] = entry
        // Weak: the transport may hold the callback past the transfer's end.
        let report: Report = { [weak self, weak entry] received in
            Task { @MainActor [weak self, weak entry] in
                guard let self, let entry else { return }
                self.report(received, for: entry)
            }
        }
        entry.task = Task { @MainActor in
            let result: Result<Fetched?, Error>
            do { result = .success(try await transfer(report)) } catch { result = .failure(error) }
            // Freed first, so a fetch arriving after this starts a new transfer rather than
            // joining a finished one. Already gone when `cancel` ended it.
            guard self.entries[id] === entry else { return }
            self.entries[id] = nil
            self.end(entry, with: result)
        }
        return entry
    }

    /// Resumes every waiter with `result` and clears the ring if it is this transfer's. The
    /// held download's failure with nobody waiting is kept for `takeFailure`.
    private func end(_ entry: Entry, with result: Result<Fetched?, Error>) {
        if heldEntry === entry, let shown = storedHeld {
            heldEntry = nil
            held = nil
            if entry.joined.isEmpty, case .failure(let error) = result, !(error is CancellationError) {
                unreported = Failure(id: shown.id, purpose: shown.purpose, error: error)
            }
        }
        let waiters = entry.waiters
        entry.waiters = [:]
        for continuation in waiters.values { continuation.resume(with: result) }
    }

    /// The reader's download that failed while no page waited on it, once: the page
    /// coming back reports it rather than the download vanishing without a word.
    public func takeFailure() -> Failure? {
        defer { unreported = nil }
        return unreported
    }

    /// A cancelled caller stops waiting; the last one out ends a transfer nobody keeps.
    private func leave(_ waiter: UUID, id: String) {
        guard let entry = entries[id], let continuation = entry.waiters.removeValue(forKey: waiter) else { return }
        entry.joined.remove(waiter)
        continuation.resume(throwing: CancellationError())
        guard entry.waiters.isEmpty, !entry.kept else { return }
        entries[id] = nil
        entry.task?.cancel()
    }

    /// Progress for the held download, kept honest:
    /// - IDENTITY: a callback from a transfer the ring no longer describes (cancelled, or a
    ///   prefetch nobody adopted) is dropped.
    /// - MONOTONIC: each chunk hops onto the main actor in its own task, and that enqueue
    ///   order is not FIFO-guaranteed, so a late-landing smaller value would run the bar
    ///   backwards. The received figure only ever grows.
    /// - COALESCED: a 40 MB file is ~56 MB of base64 in ~32 KB chunks, ~1.7k callbacks, each
    ///   of which would redraw the page. One percent of the file is the smallest step worth
    ///   a redraw; the final chunk always lands so the bar reaches its end.
    private func report(_ received: Int, for entry: Entry) {
        guard heldEntry === entry, var current = storedHeld,
              let total = current.expectedBytes, total > 0 else { return }
        let clamped = min(received, total)
        if let shown = current.progress {
            guard clamped > shown.received,
                  clamped >= shown.received + total / 100 || clamped >= total else { return }
        }
        current.progress = (clamped, total)
        held = current
    }
}

#if !os(Linux)
extension GramDownloadStore: Observable {}
#endif
