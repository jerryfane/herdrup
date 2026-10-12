import Foundation
import HerdrKit
import Network

/// The App-side context `TypingLatencyRecorder` attributes keys to: the machine the app
/// is connected to (its saved nickname when there is one) and the network the phone is on.
///
/// The network comes from one `NWPathMonitor` started on first use. A path change while a
/// terminal is open is forwarded to the recorder so keys typed after a Wi-Fi → cellular
/// handover are counted under cellular.
final class TypingLatencyContext: @unchecked Sendable {
    static let shared = TypingLatencyContext()

    private let lock = NSLock()
    private let monitor = NWPathMonitor()
    private var _hostLabel = "unknown host"
    private var _network = "other"

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(network: Self.label(for: path))
        }
        monitor.start(queue: DispatchQueue(label: "herdrup.typing-latency.path", qos: .utility))
    }

    /// The machine following terminal streams belong to.
    var hostLabel: String {
        lock.lock(); defer { lock.unlock() }
        return _hostLabel
    }

    /// "Wi-Fi", "cellular", "wired" or "other".
    var network: String {
        lock.lock(); defer { lock.unlock() }
        return _network
    }

    /// The app connected to `host` (the SSH address the transport reports to the recorder),
    /// shown as `label`.
    func connected(host: String, label: String) {
        lock.lock()
        _hostLabel = label
        lock.unlock()
        TypingLatencyRecorder.shared.setLabel(label, forHost: host)
    }

    private func update(network: String) {
        lock.lock()
        let changed = _network != network
        _network = network
        lock.unlock()
        if changed { TypingLatencyRecorder.shared.setNetwork(network) }
    }

    private static func label(for path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "other"
    }
}
