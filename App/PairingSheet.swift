import HerdrKit
import SwiftUI
import UIKit

// MARK: - Adapters

/// The app's real store, seen through the coordinator's protocol.
///
/// `add` already has the contract the coordinator needs: it persists the secret FIRST and
/// returns false WITHOUT recording the host if that fails, so a false here never leaves a
/// half-written host behind.
extension SavedHostsStore: PairingCoordinator.HostStore {
    func addPairedHost(nickname: String, host: String, username: String,
                       privateKeyPEM: String) -> Bool {
        add(nickname: nickname, host: host, username: username, secret: .key(privateKeyPEM))
    }
}

/// The app's real pin store, seen through the coordinator's protocol. The signature already
/// matches; this states the conformance rather than re-implementing anything.
extension KeychainHostKeyPolicy: PairingCoordinator.HostKeyPinner {}

// MARK: - The sheet

/// Scan a pairing code and connect, without typing anything.
///
/// This view owns the CAMERA and the PHASES. It owns no pairing logic: parsing is
/// `Pairing.parse`, and everything after a successful parse is `PairingCoordinator` — both
/// in HerdrKit, both tested. What is left here is deliberately the part with no decisions
/// in it, because this file cannot be built or run on the machine it was written on.
struct PairingSheet: View {
    @ObservedObject var store: SavedHostsStore
    /// Called with the paired host's nickname once it is saved, so the caller can connect.
    var onPaired: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .scanning
    /// Bumped to rebuild the scanner after a failure, which restarts capture cleanly
    /// rather than reaching into the controller.
    @State private var scannerGeneration = 0

    private enum Phase: Equatable {
        case scanning
        case unavailable(QRScannerUnavailable)
        case pairing
        case failed(String)
        case paired(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                content
            }
            .navigationTitle("Scan to connect")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.textDim)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            scanner
        case .unavailable(let reason):
            message(
                title: "Can't use the camera",
                body: reason.message,
                systemImage: "camera.fill",
                tint: Palette.textDim,
                primary: reason.offersSettings ? ("Open Settings", openSettings) : nil)
        case .pairing:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(Palette.text)
                Text("Connecting…").font(Typography.app(15)).foregroundStyle(Palette.textDim)
            }
        case .failed(let why):
            message(
                title: "Pairing didn't work",
                body: why,
                systemImage: "exclamationmark.triangle.fill",
                tint: Palette.died,
                primary: ("Try again", { phase = .scanning; scannerGeneration += 1 }))
        case .paired(let nickname):
            message(
                title: "Connected",
                body: "\(nickname) is saved on this device. You can reach it any time from "
                    + "the machine list.",
                systemImage: "checkmark.seal.fill",
                tint: Palette.done,
                primary: ("Open it", { dismiss(); onPaired(nickname) }))
        }
    }

    private var scanner: some View {
        VStack(spacing: 0) {
            ZStack {
                QRScannerView(onFound: handleScan, onUnavailable: { phase = .unavailable($0) })
                    .id(scannerGeneration)
                // A frame to aim with. Without one people hold the phone too close and the
                // code never fills the sensor, which reads as "the scanner is broken".
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Palette.text.opacity(0.85), lineWidth: 3)
                    .frame(width: 230, height: 230)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)

            VStack(spacing: 8) {
                Text("On your computer, run").font(Typography.app(13))
                    .foregroundStyle(Palette.textDim)
                Text("herdr pair").font(Typography.machine(16, .semibold))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("then point the camera at the code it prints.")
                    .font(Typography.app(13)).foregroundStyle(Palette.textDim)
            }
            .multilineTextAlignment(.center)
            .padding(20)
        }
    }

    private func message(
        title: String, body: String, systemImage: String, tint: Color,
        primary: (String, () -> Void)?
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(tint)
            Text(title).font(Typography.app(19, .semibold)).foregroundStyle(Palette.text)
            Text(body).font(Typography.app(14)).foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
            if let (label, action) = primary {
                Button(action: action) {
                    Text(label).font(Typography.app(16, .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Palette.text).foregroundStyle(Palette.ground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(28)
    }

    // MARK: - Actions

    /// A scanned string. Parsing happens FIRST and on this thread, because it is cheap and
    /// because a QR that is not a pairing code (a URL, a wifi code — a camera reports
    /// whatever is in frame) must not put the sheet into a connecting state it then has to
    /// back out of.
    private func handleScan(_ raw: String) {
        let payload: Pairing.Payload
        do {
            payload = try Pairing.parse(qrText: raw)
        } catch let error as Pairing.Error {
            phase = .failed(error.userFacingMessage)
            return
        } catch {
            phase = .failed(Pairing.Error.notAPairingCode.userFacingMessage)
            return
        }

        phase = .pairing
        let coordinator = PairingCoordinator(store: store, pinner: KeychainHostKeyPolicy.shared)
        let label = UIDevice.current.name
        // Awaited on the MAIN actor deliberately, NOT in a detached task. The coordinator
        // sends only the blocking socket round trip off-actor; the pin and the store write
        // must stay here, because `addPairedHost` mutates an `@Published` property and
        // SwiftUI does not allow that from a background thread.
        Task {
            do {
                let nickname = try await coordinator.completePairing(
                    payload: payload, deviceLabel: label)
                phase = .paired(nickname)
            } catch let failure as PairingCoordinator.Failure {
                phase = .failed(failure.userFacingMessage)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
