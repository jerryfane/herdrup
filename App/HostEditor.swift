import HerdrKit
import SwiftUI
import UIKit

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
    /// Whether this host authenticates with a key or a password (segmented picker).
    @State private var authKind: SavedAuthKind
    /// The password (password mode). Masked by a SecureField, so unlike the key it can
    /// be entered inline; write-only on edit (blank keeps the stored one).
    @State private var password = ""
    @State private var error: String?
    @State private var keyError: String?

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
            _authKind = State(initialValue: .key)
        case .edit(let h):
            editing = h
            _nickname = State(initialValue: h.nickname ?? "")
            _host = State(initialValue: h.host)
            _username = State(initialValue: h.username)
            _authKind = State(initialValue: h.auth)
        }
    }

    private var endpoint: HostEndpoint? { HostEndpoint.parse(host) }
    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedKey: String { keyPEM.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hostInvalid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && endpoint == nil
    }
    /// Add requires the chosen secret; edit keeps the existing one when the field is
    /// left blank (whichever auth kind).
    private var canSave: Bool {
        guard endpoint != nil, !trimmedUser.isEmpty else { return false }
        if editing != nil { return true }
        return authKind == .key ? !trimmedKey.isEmpty : !password.isEmpty
    }

    /// The secret to persist, or nil when the field is blank (edit keeps the current one).
    private func currentSecret() -> HostSecret? {
        switch authKind {
        case .key: return trimmedKey.isEmpty ? nil : .key(trimmedKey)
        case .password: return password.isEmpty ? nil : .password(password)
        }
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
                        authPicker
                        if authKind == .key { keyRow } else { passwordRow }
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
        let secret = currentSecret()
        let ok: Bool
        if let editing {
            // nil secret = keep the stored one (blank field on edit).
            ok = store.update(editing, nickname: nickname, host: host, username: trimmedUser, secret: secret)
        } else if let secret {
            ok = store.add(nickname: nickname, host: host, username: trimmedUser, secret: secret)
        } else {
            ok = false  // add needs a secret; canSave already prevents this — defensive.
        }
        if !ok { error = "Couldn't save this host. Check the fields (a key or password is required) and try again." }
        return ok
    }

    private func saveAndConnect() {
        guard let ep = endpoint, save() else { return }
        // Add mode requires the secret, so it is in hand here — connect straight away.
        let creds: SSHCredentials
        switch authKind {
        case .key:
            creds = SSHCredentials(host: ep.host, port: ep.port, username: trimmedUser,
                                   privateKeyPEM: trimmedKey, remoteSocketPath: "")
        case .password:
            creds = SSHCredentials(host: ep.host, port: ep.port, username: trimmedUser,
                                   password: password, remoteSocketPath: "")
        }
        onConnect(creds)
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

    /// Choose how this host authenticates. Switching hides/shows the key vs password row.
    private var authPicker: some View {
        Picker("Auth", selection: $authKind) {
            Text("Key").tag(SavedAuthKind.key)
            Text("Password").tag(SavedAuthKind.password)
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 2)
    }

    /// The password field. A SecureField masks the value, so unlike the key it is safe
    /// to enter inline; on edit it starts blank and the stored password is kept unless a
    /// new one is typed. Stored in the Keychain (device-only), same as the key.
    private var passwordRow: some View {
        HStack {
            Text("Password").font(Typography.app(15)).foregroundStyle(Palette.textDim)
            SecureField(editing == nil ? "password" : "saved · type to replace", text: $password)
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

    /// The key is NEVER rendered on screen (the connect screen can be screenshotted onto
    /// an open tailnet port, and a screen recording would otherwise capture it). Instead
    /// it is pasted from the clipboard straight into memory / the Keychain, and only a
    /// "key set" confirmation is shown.
    private var keySheet: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Copy your ed25519 private key (PEM) to the clipboard, then paste it here. It is stored in the Keychain (device-only) and sent over the SSH connection; it is never displayed, so it can't appear in a screenshot.")
                        .font(Typography.app(13)).foregroundStyle(Palette.textDim)

                    Button { pasteKeyFromClipboard() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.clipboard").font(.system(size: 15, weight: .semibold))
                            Text("Paste key from clipboard").font(Typography.app(15, .semibold))
                        }
                        .foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    if !keyPEM.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.done)
                            Text("Key set").font(Typography.app(15)).foregroundStyle(Palette.text)
                            Spacer(minLength: 8)
                            Button("Clear") { keyPEM = ""; keyError = nil }
                                .font(Typography.app(14)).foregroundStyle(Palette.died)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let keyError { caption(keyError, color: Palette.died) }
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

    /// Ingest a PEM key from the clipboard WITHOUT rendering it. Loosely sanity-checks it
    /// looks like a PEM private key so a stray clipboard string isn't stored as a key.
    private func pasteKeyFromClipboard() {
        guard let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else {
            keyError = "Nothing to paste. Copy your private key to the clipboard first."
            return
        }
        guard s.contains("PRIVATE KEY") else {
            keyError = "That doesn't look like a private key (expected a PEM block)."
            return
        }
        keyPEM = s
        keyError = nil
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
