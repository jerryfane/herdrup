import SwiftUI
import HerdrKit

/// One machine home, with each grant retaining its own authenticated connection,
/// pane, Gram permissions, push routing, and leave action.
struct SharedMachineHomeView: View {
    let access: GuestAccess
    let onBack: (() -> Void)?
    let onLeave: () -> Void
    @ObservedObject private var store = SharedMachinesStore.shared
    @State private var settingsAccess: GuestAccess?
    @State private var settingsConnection: GuestConnection?

    private var peers: [GuestAccess] {
        store.groups.first { $0.id == SharedMachineGroup.Identity(access) }?.accesses ?? [access]
    }

    var body: some View {
        if peers.count == 1, let only = peers.first {
            GuestHomeView(access: only, connect: { try GuestConnection.open(only) },
                          onBack: onBack, onLeave: leftShare)
                .id(only.id)
        } else {
            TabView {
                VStack(spacing: 0) {
                    SectionTopBar(title: "Agents", leading: {
                        if let onBack {
                            SectionBackSlot(.leading) {
                                SectionBarButton(icon: "chevron.left", label: "Machines", identifier: "guest-home-back", action: onBack)
                            }
                        }
                    }) {
                        if let onBack {
                            SectionBackSlot(.trailing) {
                                SectionBarButton(icon: "chevron.left", label: "Machines", identifier: "guest-home-back", action: onBack)
                            }
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(access.machineLabel).font(Typography.app(20, .bold))
                                    .accessibilityIdentifier("guest-home-title")
                                Text("Shared by \(access.ownerName) · \(peers.count) agents")
                                    .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            ForEach(peers) { peer in
                                GuestHomeView(access: peer, connect: { try GuestConnection.open(peer) },
                                              embedded: true, onBack: nil, onLeave: leftShare)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .background(Palette.ground.ignoresSafeArea())
                .tabItem { Label("Agents", systemImage: "square.grid.2x2.fill") }

                NavigationStack {
                    List(peers) { peer in
                        Button {
                            settingsConnection = try? GuestConnection.open(peer)
                            settingsAccess = peer
                        } label: {
                            Label(peer.agentName, systemImage: "person.crop.circle")
                        }
                    }
                    .navigationTitle("Shared access")
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(Palette.text)
            .sheet(item: $settingsAccess) { peer in
                GuestSettingsView(access: peer, fingerprint: settingsConnection?.fingerprint,
                                  client: settingsConnection?.client) {
                    store.remove(peer)
                    settingsAccess = nil
                    settingsConnection = nil
                    leftShare()
                }
            }
        }
    }

    private func leftShare() {
        if !store.groups.contains(where: { $0.id == SharedMachineGroup.Identity(access) }) {
            onLeave()
        }
    }
}
