import Foundation
import HerdrKit

/// Machines someone else shared with this phone ("Shared with you"). Each entry is a
/// grant for one agent on one machine; it holds no secret (the device key lives in
/// the Keychain), so the list is plain JSON in UserDefaults.
@MainActor
final class SharedMachinesStore: ObservableObject {
    static let shared: SharedMachinesStore = {
        #if DEBUG
        // Screenshot mocks and UI tests never read or write the real list; the guest
        // home mocks start with the mock share, which Leave then removes.
        if let mode = ScreenshotMock.mode {
            let seeded = mode == .guest || mode == .guestSettings ? [GuestMockTransport.access] : []
            return SharedMachinesStore(defaults: nil, machines: seeded)
        }
        #endif
        return SharedMachinesStore(defaults: .standard)
    }()

    static let defaultsKey = "dev.herdr.sharedMachines.v1"

    /// Nil keeps the list in memory only (screenshot mocks and UI tests).
    private let defaults: UserDefaults?

    @Published private(set) var machines: [GuestAccess]

    init(defaults: UserDefaults?, machines: [GuestAccess] = []) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([GuestAccess].self, from: data) {
            self.machines = decoded
        } else {
            self.machines = machines
        }
    }

    /// Adds a grant, replacing any earlier one with the same id (accepting a fresh
    /// invite from the same host as the same guest refreshes it in place).
    func add(_ access: GuestAccess) {
        if let index = machines.firstIndex(where: { $0.id == access.id }) {
            machines[index] = access
        } else {
            machines.append(access)
        }
        persist()
    }

    func remove(_ access: GuestAccess) {
        machines.removeAll { $0.id == access.id }
        persist()
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(machines) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// An invite waiting on the Accept screen. Identifiable so a second link opened while
/// one is showing replaces it rather than being ignored.
struct PendingGuestInvite: Identifiable {
    let id = UUID()
    let invite: GuestInvite
}

/// Where every invite enters the app (a tapped link, a paste, a scan). RootView
/// presents whatever lands here.
@MainActor
final class GuestInviteRouter: ObservableObject {
    static let shared = GuestInviteRouter()

    @Published var pending: PendingGuestInvite?
    /// Why the last link could not be read, shown as an alert.
    @Published var failure: String?

    /// Parses `text` as an invite and presents it, or records why it isn't one.
    func open(_ text: String) {
        do {
            pending = PendingGuestInvite(invite: try GuestInvite.parse(text))
        } catch {
            failure = GuestDevice.describe(error, machine: "")
        }
    }

    /// Whether a URL is an invite link in either form.
    static func isInviteLink(_ url: URL) -> Bool {
        let text = url.absoluteString
        if text.hasPrefix(GuestInvite.appLinkPrefix) { return true }
        return url.scheme == "https" && url.path == "/i" && url.fragment?.isEmpty == false
    }
}
