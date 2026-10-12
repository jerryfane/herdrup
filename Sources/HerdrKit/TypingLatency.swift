import Foundation

/// One keystroke measured from the key press to the frame that drew its echo.
///
/// Every interval is measured from the key's own press time (t0), so two keys that
/// left in the same batch share their send, ack and echo stamps but keep their own
/// totals: the second key of a burst waited less.
public struct TypingLatencySample: Sendable, Equatable {
    /// Press to the moment its batch went to `sendText` (time spent behind the
    /// stop-and-wait send in flight).
    public let queueWait: TimeInterval
    /// Press to `sendText` returning (the server's reply to the batch).
    public let keyToAck: TimeInterval
    /// Press to the first stream output after the batch was sent.
    public let keyToEcho: TimeInterval
    /// Press to the first completed draw after that output.
    public let keyToPaint: TimeInterval
    /// Keys in the batch this key was sent with.
    public let batchSize: Int
    /// Bytes in the batch this key was sent with.
    public let batchBytes: Int
}

/// Median, slow (90th percentile) and worst value of one interval, in milliseconds.
public struct TypingLatencyStats: Sendable, Equatable {
    public let median: Double
    public let p90: Double
    public let max: Double

    /// Nearest-rank percentiles over `values` (seconds), reported in milliseconds.
    /// nil when there is nothing to summarise.
    public init?(seconds values: [TimeInterval]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        median = TypingLatencyStats.percentile(sorted, 0.5) * 1000
        p90 = TypingLatencyStats.percentile(sorted, 0.9) * 1000
        max = sorted[sorted.count - 1] * 1000
    }

    /// Nearest-rank percentile of an ascending, non-empty array: the smallest value with
    /// at least `p` of the values at or below it.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[Swift.min(Swift.max(rank, 1), sorted.count) - 1]
    }
}

/// The numbers for one (host, network) pair.
public struct TypingLatencyReport: Sendable, Equatable, Identifiable {
    public let host: String
    public let network: String
    public var id: String { host + "\u{1F}" + network }
    /// Keys measured end to end.
    public let count: Int
    /// Keys given up on: no output within the attribution window, or never finished.
    public let dropped: Int
    /// Keys whose send failed and were never delivered (the app drops a failed batch).
    public let lost: Int
    public let queueWait: TypingLatencyStats?
    public let keyToAck: TypingLatencyStats?
    public let keyToEcho: TypingLatencyStats?
    public let keyToPaint: TypingLatencyStats?
    /// Mean keys per `sendText` over the measured keys (0 without samples).
    public let meanBatchSize: Double
    /// Mean bytes per `sendText` over the measured keys (0 without samples).
    public let meanBatchBytes: Double
    /// Requests to this host that went over the held `api-bridge --multi` channel.
    public let heldRequests: Int
    /// Requests to this host that took the per-request exec path.
    public let perRequestRequests: Int
    /// Times the held channel failed to open although the host advertised it.
    public let heldOpenFailures: Int

    /// Share of this host's requests that used the held channel, nil before any request.
    public var heldShare: Double? {
        let total = heldRequests + perRequestRequests
        return total == 0 ? nil : Double(heldRequests) / Double(total)
    }

    /// The block in plain words, one line each; shared by Settings and the copied report.
    public func plainLines() -> [String] {
        var lines: [String] = []
        lines.append(Self.line("Key to screen", keyToPaint))
        lines.append(Self.line("Key to echo", keyToEcho))
        lines.append(Self.line("Key to server reply", keyToAck))
        lines.append(Self.line("Waiting to send", queueWait))
        if let share = heldShare {
            let total = heldRequests + perRequestRequests
            lines.append("Held channel: \(Int((share * 100).rounded()))% of \(total) requests")
        } else {
            lines.append("Held channel: no requests seen")
        }
        if heldOpenFailures > 0 {
            lines.append("Held channel failed to open \(heldOpenFailures) time\(heldOpenFailures == 1 ? "" : "s"): the herdr command "
                + "on this machine is probably older than its server. Update or remove the old "
                + "copy (`command -v herdr` on that machine).")
        }
        lines.append("\(count) keys measured, \(dropped) not attributable, "
            + String(format: "%.1f keys (%.1f bytes) per send", meanBatchSize, meanBatchBytes))
        if lost > 0 { lines.append("\(lost) keys lost: their send failed") }
        return lines
    }

    private static func line(_ label: String, _ stats: TypingLatencyStats?) -> String {
        guard let stats else { return "\(label): no data" }
        return "\(label): \(ms(stats.median)) typical, \(ms(stats.p90)) slow (90%), \(ms(stats.max)) worst"
    }

    private static func ms(_ value: Double) -> String { "\(Int(value.rounded())) ms" }
}

/// Measures typing latency on the real device: key press → batch sent → server reply →
/// echo output → painted frame, per (host, network).
///
/// Built into every configuration (Release/TestFlight included) so the owner can read
/// numbers from their own phone. Every hook is a few comparisons over the handful of keys
/// still in flight, under one lock; nothing here changes what is sent or when.
///
/// Attribution is deliberately simple: output arriving after a batch was sent is taken as
/// that batch's echo. A key whose batch sees no output within `attributionWindow` of being
/// SENT (a key the program never echoes, a lost key) is dropped and counted rather than
/// guessed at. Waiting in the queue is never held against a key, so slow sends still show
/// up in the numbers instead of vanishing. Output before a key's batch is sent never
/// counts for it (it is the agent's own output).
public final class TypingLatencyRecorder: @unchecked Sendable {
    public static let shared = TypingLatencyRecorder()

    /// Keys whose batch has had no output this long after being sent are unattributable.
    public static let attributionWindow: TimeInterval = 2
    /// Keys never finished this long after the press (the pane went to the background, a
    /// send never returned) are given up so they cannot pile up. Longer than a request's
    /// 60 s timeout, so a stalled send is still measured when it finally goes through.
    static let finishWindow: TimeInterval = 90
    /// Samples kept per (host, network).
    public static let ringCapacity = 1000
    /// Upper bound on keys in flight; the oldest beyond it is dropped.
    static let maxPending = 256

    private struct Context: Hashable {
        let host: String
        let network: String
    }

    private struct PendingKey {
        let t0: TimeInterval
        let context: Context
        var sent: TimeInterval?
        var ack: TimeInterval?
        var echo: TimeInterval?
        var paint: TimeInterval?
        var batchSize = 0
        var batchBytes = 0
    }

    private struct Ring {
        private(set) var samples: [TypingLatencySample] = []
        private var next = 0

        mutating func append(_ sample: TypingLatencySample) {
            if samples.count < TypingLatencyRecorder.ringCapacity {
                samples.append(sample)
            } else {
                samples[next] = sample
                next = (next + 1) % TypingLatencyRecorder.ringCapacity
            }
        }
    }

    private struct Routes {
        var held = 0
        var perRequest = 0
        var openFailures = 0
    }

    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var context = Context(host: "unknown host", network: "unknown")
    private var pending: [PendingKey] = []
    private var rings: [Context: Ring] = [:]
    private var dropped: [Context: Int] = [:]
    /// Keys whose send failed: the app drops those batches, so they never reached the host.
    private var lost: [Context: Int] = [:]
    private var routes: [String: Routes] = [:]
    /// Transport host (address) → the label `begin(host:)` uses for it.
    private var labels: [String: String] = [:]

    /// `clock` must be monotonic; tests inject a fake one.
    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Context

    /// The host and network following keys are attributed to.
    public func begin(host: String, network: String) {
        locked { context = Context(host: host, network: network) }
    }

    /// The network changed under a running session (Wi-Fi → cellular).
    public func setNetwork(_ network: String) {
        locked { context = Context(host: context.host, network: network) }
    }

    /// Join the transport's host string (`noteRoute`) to the label `begin` uses for it,
    /// so a machine reads as its nickname rather than its address in both places.
    public func setLabel(_ label: String, forHost host: String) {
        locked { labels[host] = label }
    }

    // MARK: Keystroke path

    /// A key reached the terminal's input path.
    public func keyPressed() {
        let now = clock()
        locked {
            prune(now: now)
            if pending.count >= Self.maxPending {
                count(dropped: pending.removeFirst())
            }
            pending.append(PendingKey(t0: now, context: context))
        }
    }

    /// The pending keys without a send time just went out as one batch of `byteCount` bytes.
    public func batchSent(byteCount: Int) {
        let now = clock()
        locked {
            let keys = pending.reduce(0) { $1.sent == nil ? $0 + 1 : $0 }
            guard keys > 0 else { return }
            for index in pending.indices where pending[index].sent == nil {
                pending[index].sent = now
                pending[index].batchSize = keys
                pending[index].batchBytes = byteCount
            }
        }
    }

    /// The send in flight returned. A `failed` batch never reached the terminal (the app
    /// drops it); its keys are counted as lost instead of measured.
    public func batchAcked(failed: Bool = false) {
        let now = clock()
        locked {
            if failed {
                pending.removeAll { key in
                    guard key.sent != nil, key.ack == nil else { return false }
                    lost[key.context, default: 0] += 1
                    return true
                }
                return
            }
            for index in pending.indices where pending[index].sent != nil && pending[index].ack == nil {
                pending[index].ack = now
            }
            finalize()
        }
    }

    /// Stream output arrived for the focused pane.
    public func outputArrived() {
        let now = clock()
        locked {
            prune(now: now)
            for index in pending.indices where pending[index].sent != nil && pending[index].echo == nil {
                pending[index].echo = now
            }
        }
    }

    /// The focused pane finished drawing a complete frame.
    public func painted() {
        let now = clock()
        locked {
            for index in pending.indices where pending[index].echo != nil && pending[index].paint == nil {
                pending[index].paint = now
            }
            finalize()
        }
    }

    // MARK: Transport

    /// One request to `host` went over the held channel (`held`) or the per-request path.
    public func noteRoute(host: String, held: Bool) {
        locked {
            let key = labels[host] ?? host
            if held { routes[key, default: Routes()].held += 1 } else { routes[key, default: Routes()].perRequest += 1 }
        }
    }

    /// The held channel to `host` failed to open even though the host advertised it.
    public func noteHeldChannelOpenFailed(host: String) {
        locked { routes[labels[host] ?? host, default: Routes()].openFailures += 1 }
    }

    /// Route counts for one host (its label when one is set), nil before any request.
    public func routeReport(host: String) -> (held: Int, perRequest: Int, openFailures: Int)? {
        locked {
            guard let route = routes[labels[host] ?? host] else { return nil }
            return (route.held, route.perRequest, route.openFailures)
        }
    }

    // MARK: Reports

    /// One report per (host, network) seen, ordered by host then network.
    public func report() -> [TypingLatencyReport] {
        locked {
            let contexts = Set(rings.keys).union(dropped.keys).union(lost.keys)
                .sorted { ($0.host, $0.network) < ($1.host, $1.network) }
            return contexts.map { context in
                let samples = rings[context]?.samples ?? []
                let route = routes[context.host] ?? Routes()
                let n = Double(samples.count)
                return TypingLatencyReport(
                    host: context.host, network: context.network,
                    count: samples.count, dropped: dropped[context] ?? 0, lost: lost[context] ?? 0,
                    queueWait: TypingLatencyStats(seconds: samples.map(\.queueWait)),
                    keyToAck: TypingLatencyStats(seconds: samples.map(\.keyToAck)),
                    keyToEcho: TypingLatencyStats(seconds: samples.map(\.keyToEcho)),
                    keyToPaint: TypingLatencyStats(seconds: samples.map(\.keyToPaint)),
                    meanBatchSize: n == 0 ? 0 : Double(samples.reduce(0) { $0 + $1.batchSize }) / n,
                    meanBatchBytes: n == 0 ? 0 : Double(samples.reduce(0) { $0 + $1.batchBytes }) / n,
                    heldRequests: route.held, perRequestRequests: route.perRequest,
                    heldOpenFailures: route.openFailures)
            }
        }
    }

    /// The whole report as plain text the owner can paste into an issue or chat.
    public func reportText(appVersion: String? = nil, build: String? = nil) -> String {
        var lines = ["herdrup typing latency"]
        switch (appVersion, build) {
        case let (version?, build?): lines.append("app \(version) (\(build))")
        case let (version?, nil): lines.append("app \(version)")
        case let (nil, build?): lines.append("app build \(build)")
        case (nil, nil): break
        }
        let reports = report()
        if reports.isEmpty {
            lines.append("No typing measured yet.")
        }
        for report in reports {
            lines.append("")
            lines.append("\(report.host), \(report.network)")
            lines.append(contentsOf: report.plainLines().map { "  " + $0 })
        }
        return lines.joined(separator: "\n")
    }

    /// Forget every sample, drop count, route count and key in flight. Context and
    /// host labels are kept: they describe the live session, not the measurements.
    public func reset() {
        locked {
            pending.removeAll()
            rings.removeAll()
            dropped.removeAll()
            lost.removeAll()
            routes.removeAll()
        }
    }

    /// The pane being typed into stopped: keys still queued behind its send will never be
    /// sent, so they are dropped and counted now instead of being claimed by the next
    /// pane's first batch.
    public func abandonUnsent() {
        locked {
            pending.removeAll { key in
                guard key.sent == nil else { return false }
                count(dropped: key)
                return true
            }
        }
    }

    // MARK: Internals (call with the lock held)

    private func prune(now: TimeInterval) {
        guard !pending.isEmpty else { return }
        pending.removeAll { key in
            let unechoed = key.sent.map { key.echo == nil && now - $0 > Self.attributionWindow } ?? false
            let stale = unechoed || now - key.t0 > Self.finishWindow
            if stale { count(dropped: key) }
            return stale
        }
    }

    private func count(dropped key: PendingKey) {
        dropped[key.context, default: 0] += 1
    }

    private func finalize() {
        guard !pending.isEmpty else { return }
        pending.removeAll { key in
            guard let sent = key.sent, let ack = key.ack, let echo = key.echo, let paint = key.paint else {
                return false
            }
            rings[key.context, default: Ring()].append(TypingLatencySample(
                queueWait: sent - key.t0, keyToAck: ack - key.t0, keyToEcho: echo - key.t0,
                keyToPaint: paint - key.t0, batchSize: key.batchSize, batchBytes: key.batchBytes))
            return true
        }
    }
}
