import Foundation
import XCTest
@testable import HerdrKit

/// `GuestPushCoordinator` against a scripted phone and host: what the host ends up holding
/// is what decides whether the guest is notified, so each test checks the host's side.
final class GuestPushCoordinatorTests: XCTestCase {

    /// The share's host: answers the push methods and keeps the registered tokens.
    final class Host: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _registered: Set<String> = []
        private var failures: [String: Int] = [:]

        var calls: [String] { lock.withLock { _calls } }
        var registered: Set<String> { lock.withLock { _registered } }

        /// The next `count` calls of `method` fail.
        func fail(_ method: String, times count: Int = 1) { lock.withLock { failures[method] = count } }

        func answer(_ requestLine: String) -> String {
            let request = (try? JSONSerialization.jsonObject(with: Data(requestLine.utf8))) as? [String: Any] ?? [:]
            let id = request["id"] as? String ?? ""
            let method = request["method"] as? String ?? ""
            let token = (request["params"] as? [String: Any])?["device_token"] as? String ?? ""
            return lock.withLock {
                _calls.append(method)
                if let left = failures[method], left > 0 {
                    failures[method] = left - 1
                    return #"{"id":"\#(id)","error":{"code":"device_registry_save_failed","message":"disk full"}}"#
                }
                switch method {
                case "notifications.register_device": _registered.insert(token)
                case "notifications.unregister_device": _registered.remove(token)
                default: break
                }
                return #"{"id":"\#(id)","result":{"type":"ok"}}"#
            }
        }
    }

    struct HostTransport: HerdrTransport {
        let host: Host
        func roundTrip(_ requestLine: String) async throws -> String { host.answer(requestLine) }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// iOS and the push relay. Enrollment answers at once unless `holdEnrollment` is set,
    /// in which case it waits for `releaseEnrollment()`.
    actor Phone {
        var authorization: PushAuthorization = .granted
        var token: String? = "ab12cd34ab12cd34ab12cd34ab12cd34"
        var holdEnrollment = false
        private var enrollmentWaiters: [CheckedContinuation<Void, Never>] = []
        private var enrollmentStarted: [CheckedContinuation<Void, Never>] = []
        private var enrollments = 0

        func set(authorization: PushAuthorization) { self.authorization = authorization }
        func set(token: String?) { self.token = token }
        func hold() { holdEnrollment = true }

        func enroll() async -> String? {
            enrollments += 1
            enrollmentStarted.forEach { $0.resume() }
            enrollmentStarted = []
            if holdEnrollment {
                await withCheckedContinuation { enrollmentWaiters.append($0) }
            }
            return "hpr1.capability"
        }

        /// Returns once an enrollment has started.
        func enrollmentBegan() async {
            if enrollments > 0 { return }
            await withCheckedContinuation { enrollmentStarted.append($0) }
        }

        func releaseEnrollment() {
            holdEnrollment = false
            enrollmentWaiters.forEach { $0.resume() }
            enrollmentWaiters = []
        }
    }

    let access = GuestAccess(
        guestID: "g-7f2c", guestName: "plotarmordev", machineLabel: "Mac Studio", ownerName: "Jerry",
        agentName: "llm-opt", agentTarget: "w1:p2",
        endpoint: RelayEndpoint(relay: URL(string: "https://relay.test")!, hostID: "HOST", hostPublicKey: Data(count: 32)),
        acceptedAt: Date(timeIntervalSince1970: 0))
    let features = GuestFeatures(gram: true, push: true)

    func makeCoordinator(_ phone: Phone, _ host: Host) -> GuestPushCoordinator {
        let defaults = UserDefaults(suiteName: "GuestPushCoordinatorTests-\(UUID().uuidString)")!
        return GuestPushCoordinator(
            system: GuestPushSystem(
                authorization: { await phone.authorization },
                requestAuthorization: { await phone.authorization == .granted },
                registerForRemoteNotifications: {},
                deviceToken: { await phone.token },
                tokenError: { nil },
                relayCapability: { _ in await phone.enroll() },
                connect: { _ in HerdrClient(transport: HostTransport(host: host)) }),
            defaults: defaults)
    }

    func client(_ host: Host) -> HerdrClient { HerdrClient(transport: HostTransport(host: host)) }

    // MARK: Off wins

    /// Turn off while a registration is waiting on the push relay: the registration must not
    /// land after the unregistration, or the host keeps notifying a guest whose screen says Off.
    func testTurningOffDuringARegistrationLeavesTheHostWithoutThePhone() async throws {
        let phone = Phone()
        let host = Host()
        let coordinator = makeCoordinator(phone, host)
        let client = client(host)
        await phone.hold()

        let connecting = Task { await coordinator.connected(access, client: client, features: features) }
        await phone.enrollmentBegan()
        let turningOff = Task { await coordinator.turnOff(access, client: client) }
        // Let Turn off go as far as it will before the relay answers: up to its unregistration,
        // unless it waits for the registration in flight.
        try await waitUntil(timeout: 0.5) { host.calls.contains("notifications.unregister_device") }
        await phone.releaseEnrollment()
        await connecting.value
        await turningOff.value

        XCTAssertEqual(host.registered, [], "the host still holds the phone after Off: \(host.calls)")
        XCTAssertEqual(host.calls.last, "notifications.unregister_device", "\(host.calls)")
        let status = await coordinator.state.status(for: access)
        XCTAssertEqual(status, .off)
    }

    // MARK: Retry

    /// A failed Turn off shows as a failure, and Try again retries the unregistration: it must
    /// never turn notifications back on.
    func testRetryingAFailedTurnOffUnregistersAgainAndStaysOff() async throws {
        let phone = Phone()
        let host = Host()
        let coordinator = makeCoordinator(phone, host)
        let client = client(host)
        await coordinator.connected(access, client: client, features: features)
        XCTAssertFalse(host.registered.isEmpty)

        host.fail("notifications.unregister_device")
        await coordinator.turnOff(access, client: client)
        let failed = await coordinator.state.status(for: access)
        guard case .failed = failed else { return XCTFail("a refused Turn off should show: \(failed)") }
        XCTAssertEqual(failed.action, .retry)

        await coordinator.perform(.retry, access, client: client)
        XCTAssertEqual(host.registered, [], "Try again should finish turning off: \(host.calls)")
        XCTAssertEqual(host.calls.filter { $0 == "notifications.register_device" }.count, 1, "\(host.calls)")
        let status = await coordinator.state.status(for: access)
        XCTAssertEqual(status, .off)
    }

    /// A failed registration's Try again registers.
    func testRetryingAFailedRegistrationRegisters() async throws {
        let phone = Phone()
        let host = Host()
        let coordinator = makeCoordinator(phone, host)
        let client = client(host)
        host.fail("notifications.register_device")
        await coordinator.connected(access, client: client, features: features)
        let failed = await coordinator.state.status(for: access)
        guard case .failed = failed else { return XCTFail("a refused registration should show: \(failed)") }

        await coordinator.perform(.retry, access, client: client)
        XCTAssertFalse(host.registered.isEmpty, "\(host.calls)")
        let status = await coordinator.state.status(for: access)
        XCTAssertEqual(status, .on)
    }

    /// Polls `condition` until it holds or `timeout` passes; returns whether it held.
    @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}
