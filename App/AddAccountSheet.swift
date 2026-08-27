import SwiftUI
import HerdrKit

/// Add a brand-new credential account from the app. Picks a kind + label, calls
/// `accounts.create` (the daemon derives a fresh config-home + id, writes config.toml,
/// reloads), then hands back the refreshed list + the new account so the caller can
/// chain into sign-in. No credential is written here — that's the login step.
struct AddAccountSheet: View {
    let client: HerdrClient
    /// (refreshed accounts, the newly created account if found).
    var onCreated: ([CredentialAccount], CredentialAccount?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind = "claude"
    @State private var label = ""
    @State private var busy = false
    @State private var errorText: String?

    private let kinds = ["claude", "codex", "kimi"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Picker("Kind", selection: $kind) {
                        ForEach(kinds, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    TextField("Label (e.g. Claude · work)", text: $label)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Text("A new config-home is created for this account; you'll sign in next.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(busy || label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() async {
        busy = true
        errorText = nil
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let refreshed = try await client.accountsCreate(kind: kind, label: trimmed)
            let created = refreshed.last(where: { $0.kind == kind && $0.label == trimmed })
            onCreated(refreshed, created)
            dismiss()
        } catch {
            errorText = "Couldn't add the account: \(error)"
        }
        busy = false
    }
}
