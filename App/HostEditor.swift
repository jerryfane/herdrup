import HerdrKit
import SwiftUI

/// What the `HostEditor` sheet is working on: a brand-new host, or an existing one.
enum HostEditorTarget: Identifiable {
    case add
    case edit(SavedHost)
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let h): return h.id.uuidString
        }
    }
}

/// Add or edit a saved host: nickname + host(:port) + user + private key. Saving records
/// the non-secret fields in UserDefaults and the key in the Keychain (via `SavedHostsStore`).
/// Adding also offers Save & Connect. The key is WRITE-ONLY here (never displayed — the
/// connect screen can be screenshotted onto an open port): on edit it starts blank and the
/// stored key is kept unless a new one is pasted.
struct HostEditor: View {
    let target: HostEditorTarget
    @ObservedObject var store: SavedHostsStore
    /// Save & Connect (add mode): build credentials and hand them up to connect.
    var onConnect: (SSHCredentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String
    @State private var host: String
    @State private var username: String
    @State private var keyPEM = ""
    @State private var showingKeySheet = false
    @State private var error: String?

    private let editing: SavedHost?

    init(target: HostEditorTarget, store: SavedHostsStore, onConnect: @escaping (SSHCredentials) -> Void) {
        self.target = target
        self.store = store
        self.onConnect = onConnect
        switch target {
        case .add:
            editing = nil
            _nickname = State(initialValue: "")
            _host = State(initialValue: "")
            _username = State(initialValue: "")
        case .edit(let h):
            editing = h
            _nickname = State(initialValue: h.nickname ?? "")
            _host = State(initialValue: h.host)
            _username = State(initialValue: h.username)
        }
    }

    private var endpoint: HostEndpoint? { HostEndpoint.parse(host) }
    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { keyPEM.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hostInvalid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && endpoint == nil
    }
    /// Add requires a key; edit keeps the existing one when the field is left blank.
    private var canSave: Bool {
        guard endpoint != nil, !trimmedUser.isEmpty else { return false }
        return editing != nil || !trimmedKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 10) {
                        fieldRow("Nickname", text: $nickname, placeholder: "My Mac")
                        fieldRow("Host", text: $host, placeholder: "mac.tail-scale.ts.net")
                        if hostInvalid { caption("check host or host:port", color: Palette.died) }
                        fieldRow("User", text: $username, placeholder: "jerry")
                        keyRow
                        if let error { caption(error, color: Palette.died) }

                        if editing == nil {
                            primaryButton("Save & Connect") { saveAndConnect() }
                            Button("Save without connecting") { if save() { dismiss() } }
                                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
                                .disabled(!canSave).padding(.top, 2)
                        } else {
                            primaryButton("Save") { if save() { dismiss() } }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(editing == nil ? "Add host" : "Edit host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.textDim)
                }
            }
        }
        .sheet(isPresented: $showingKeySheet) { keySheet }
    }

    // MARK: - actions

    /// Persist the host (add or update). Returns success; sets `error` on failure.
    @discardableResult
    private func save() -> Bool {
        let ok: Bool
        if let editing {
            ok = store.update(editing, nickname: nickname, host: host, username: trimmedUser, privateKeyPEM: keyPEM)
        } else {
            ok = store.add(nickname: nickname, host: host, username: trimmedUser, privateKeyPEM: trimmedKey)
        }
        if !ok { error = "Couldn't save this host. Check the fields (a private key is required) and try again." }
        return ok
    }

    private func saveAndConnect() {
        guard let ep = endpoint, save() else { return }
        // Add mode requires a key, so it is in hand here — connect straight away.
        onConnect(SSHCredentials(host: ep.host, port: ep.port, username: trimmedUser,
                                 privateKeyPEM: trimmedKey, remoteSocketPath: ""))
        dismiss()
    }

    // MARK: - rows

    private func fieldRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label).font(Typography.app(15)).foregroundStyle(Palette.textDim)
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(Typography.machine(15)).foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The key row NEVER renders the key itself — only whether one is set (the connect
    /// screen is screenshotted onto an open port, so the PEM must not be on screen).
    private var keyRow: some View {
        Button { showingKeySheet = true } label: {
            HStack {
                Text("Key").font(Typography.app(15)).foregroundStyle(Palette.textDim)
                Spacer()
                if !keyPEM.isEmpty {
                    Text(editing == nil ? "ed25519 key" : "new key")
                        .font(Typography.machine(15)).foregroundStyle(Palette.text)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.done)
                } else if editing != nil {
                    Text("saved · tap to replace").font(Typography.app(15)).foregroundStyle(Palette.textFaint)
                } else {
                    Text("Add private key").font(Typography.app(15)).foregroundStyle(Palette.textFaint)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var keySheet: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste your ed25519 private key (PEM). It is held in the Keychain (device-only) and sent over the SSH connection — never shown again.")
                        .font(Typography.app(13)).foregroundStyle(Palette.textDim)
                    TextEditor(text: $keyPEM)
                        .font(Typography.machine(13)).foregroundStyle(Palette.text)
                        .scrollContentBackground(.hidden)
                        .padding(10).background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    if !keyPEM.isEmpty {
                        Button("Clear key") { keyPEM = "" }
                            .font(Typography.app(14)).foregroundStyle(Palette.died)
                    }
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Private key")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingKeySheet = false }.foregroundStyle(Palette.textDim)
                }
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.app(16, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(canSave ? Palette.text : Palette.surface)
                .foregroundStyle(canSave ? Palette.ground : Palette.textFaint)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!canSave)
        .padding(.top, 6)
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.app(12)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }
}
