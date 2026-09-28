import SwiftUI
import HerdrKit

/// A guest's Settings tab: what was shared, by whom, the name the guest's messages
/// carry, this phone's key, and leaving. Nothing about the owner's fleet.
struct GuestSettingsView: View {
    let access: GuestAccess
    /// This phone's key fingerprint; nil while unreadable.
    let fingerprint: String?
    /// Removes the share. The device key stays: it is this install's identity.
    let onLeave: () -> Void

    @State private var confirmingLeave = false
    /// Observed so a Text size change re-renders at the new `Typography.scale`.
    @AppStorage("ui.fontScale") private var uiFontScale: Double = 1.0

    var body: some View {
        let _ = uiFontScale
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(Typography.app(20, .semibold)).foregroundStyle(Palette.text)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                ScrollView {
                    VStack(spacing: 0) {
                        GuestShellStyle.section("Shared with you").padding(.top, 14).padding(.bottom, 8)
                        GuestShellStyle.card {
                            GuestShellStyle.keyValue("Machine") { value(access.machineLabel) }
                            GuestShellStyle.divider
                            GuestShellStyle.keyValue("Shared by") { value(access.ownerName) }
                            GuestShellStyle.divider
                            GuestShellStyle.keyValue("Agent") { mono(access.agentName, Palette.text) }
                            GuestShellStyle.divider
                            GuestShellStyle.keyValue("You appear as") { mono(access.guestName, GuestShellStyle.label) }
                        }

                        GuestShellStyle.section("This device").padding(.top, 26).padding(.bottom, 8)
                        GuestShellStyle.card {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Device key")
                                    .font(Typography.app(15)).foregroundStyle(Palette.textDim)
                                Text(fingerprint ?? "Unavailable")
                                    .font(Typography.machine(13.5, .medium)).foregroundStyle(Palette.text)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("guest-settings-fingerprint")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 13)
                        }
                        Text("\(access.ownerName) sees the same key next to your name, so you can compare them.")
                            .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 30).padding(.top, 8)

                        Button { confirmingLeave = true } label: {
                            Text("Leave share")
                                .font(Typography.app(15, .semibold)).foregroundStyle(Palette.died)
                                .frame(maxWidth: .infinity).frame(height: 46)
                                .overlay(Capsule().stroke(Palette.died.opacity(0.45), lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16).padding(.top, 30)
                        .accessibilityIdentifier("guest-leave")
                        Text("You stop seeing \(access.agentName). To come back, \(access.ownerName) has to send a new invite.")
                            .font(Typography.app(13)).foregroundStyle(Palette.textFaint)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30).padding(.top, 10)
                    }
                    .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .confirmationDialog("Leave \(access.machineLabel)?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave share", role: .destructive, action: onLeave)
        } message: {
            Text("\(access.agentName) disappears from this phone.")
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).font(Typography.app(15)).foregroundStyle(Palette.text)
    }

    private func mono(_ text: String, _ color: Color) -> some View {
        Text(text).font(Typography.machine(13.5, .medium)).foregroundStyle(color)
    }
}
