import NearSignerCore
import SwiftUI

struct AccountDetailView: View {
    let model: AppModel
    let accountID: UUID

    var body: some View {
        if let owner = model.account(id: accountID) {
            AccountDetailContent(model: model, wallet: owner.wallet, account: owner.account)
        } else {
            ContentUnavailableView("Account removed", systemImage: "person.crop.circle.badge.xmark")
        }
    }
}

private struct AccountDetailContent: View {
    let model: AppModel
    let wallet: Wallet
    let account: Account
    @State private var showing: AddressKind = .name
    @State private var renaming = false
    @State private var draftName = ""
    @State private var editingAccountId = false
    @State private var draftAccountId = ""
    @State private var confirmRemove = false
    @State private var suggestionToUse: String?
    @Environment(\.dismiss) private var dismiss

    enum AddressKind: String, CaseIterable, Identifiable {
        case name = "Account name"
        case address = "Address"
        case publicKey = "Public key"

        var id: String { rawValue }
    }

    /// "Account name" only when the account has one.
    private var kinds: [AddressKind] {
        account.accountId == nil ? [.address, .publicKey] : AddressKind.allCases
    }

    private var selected: AddressKind {
        kinds.contains(showing) ? showing : kinds[0]
    }

    private var value: String {
        switch selected {
        case .name: return account.accountId ?? account.implicitAccountId
        case .address: return account.implicitAccountId
        case .publicKey: return account.publicKeyString
        }
    }

    private var explanation: String {
        switch selected {
        case .name:
            return "The named account you set for this key. Send NEAR or tokens to this name."
        case .address:
            return "Send NEAR to this address to fund a new account. It's the key's implicit account ID."
        case .publicKey:
            return "To control an existing NEAR account from this phone, add this public key to it."
        }
    }

    var body: some View {
        let suggestions = account.suggestedAccountIds(in: model.history)
        List {
            Section {
                VStack(spacing: 16) {
                    AccountAvatar(account: account, size: 64)
                    VStack(spacing: 4) {
                        Text(account.name)
                            .font(.title2.bold())
                        if model.wallets.wallets.count > 1 {
                            Text(wallet.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("Show", selection: Binding(get: { selected }, set: { showing = $0 })) {
                        ForEach(kinds) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    QRCodeView(value: value)
                        .frame(maxWidth: 220)
                    // Copy and Share below give the exact value; selecting this text would also
                    // copy the invisible line-break points.
                    DataText(value)
                        .font(selected == .name ? .body.weight(.semibold) : .footnote.monospaced())
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        CopyButton(value: value)
                            .buttonStyle(.bordered)
                        ShareLink(item: value) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Button {
                    draftAccountId = account.accountId ?? ""
                    editingAccountId = true
                } label: {
                    LabeledContent {
                        DataText(account.accountId ?? "Not set")
                            .foregroundStyle(account.accountId == nil ? Color.secondary : Color.primary)
                    } label: {
                        Label("NEAR account name", systemImage: "at")
                    }
                }
                .foregroundStyle(Color.primary)
            } footer: {
                Text("If this key controls a named account such as alice.near, add its name. The phone is offline, so it can't check the name.")
            }

            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.self) { accountId in
                        HStack {
                            Label(accountId, systemImage: "person.crop.circle")
                            Spacer()
                            Button("Use") { suggestionToUse = accountId }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                } header: {
                    Text("Seen in Requests You Approved")
                } footer: {
                    Text("Use a name only if you recognize it: an app can send a request in any account's name.")
                }
            }

            Section {
                Button {
                    draftName = account.name
                    renaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                if wallet.accounts.count > 1 {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label("Remove from list", systemImage: "minus.circle")
                    }
                }
            } footer: {
                if wallet.accounts.count > 1 {
                    Text("Removing only hides the account on this phone. Its funds stay on NEAR, and you can add it again anytime.")
                }
            }

            Section {
                if wallet.kind == .privateKey {
                    LabeledContent("Key", value: "Imported private key")
                } else {
                    LabeledContent("Derivation path") {
                        Text(account.path.description)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Advanced")
            }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename account", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Save") {
                // A blank name keeps the old one.
                if !draftName.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.renameAccount(account.id, to: draftName)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("NEAR account name", isPresented: $editingAccountId) {
            TextField("alice.near", text: $draftAccountId)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Save") { model.setAccountId(account.id, to: draftAccountId) }
            if account.accountId != nil {
                Button("Remove name", role: .destructive) { model.setAccountId(account.id, to: nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The named account this key controls.")
        }
        .alert("Use \(suggestionToUse ?? "")?", isPresented: Binding(
            get: { suggestionToUse != nil }, set: { if !$0 { suggestionToUse = nil } }
        )) {
            Button("Use name") {
                if let name = suggestionToUse { model.setAccountId(account.id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only if you know this key controls \(suggestionToUse ?? "it"). The name becomes the address shown for receiving funds, and funds sent to a wrong name go to someone else.")
        }
        .confirmationDialog("Remove \(account.name) from the list?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                dismiss()
                model.removeAccount(account.id)
            }
        } message: {
            Text("You can add it again later. Its funds are not affected.")
        }
    }
}

struct AddAccountView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var useCustomPath = false
    @State private var pathText = ""
    @State private var working = false

    /// Accounts of the active wallet, where the new account goes.
    private var book: AccountBook { model.activeWallet?.book ?? AccountBook() }

    private var customPath: BIP32Path? {
        guard let path = BIP32Path(pathText), AccountBook.isValidAccountPath(path) else { return nil }
        return path
    }

    private var path: BIP32Path? {
        guard useCustomPath else { return book.nextStandardPath }
        guard let customPath, book.account(for: customPath) == nil else { return nil }
        return customPath
    }

    private var customPathMessage: String {
        guard !pathText.isEmpty else { return "Enter 5 hardened levels, such as m/44'/397'/0'/0'/1'." }
        guard let customPath else { return "That isn't a valid path. Use 5 hardened levels, such as m/44'/397'/0'/0'/1'." }
        if book.account(for: customPath) != nil { return "You already have an account with this path." }
        return "This path is valid."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(path.map(AccountBook.defaultName(for:)) ?? "Name", text: $name)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Only you see this name. It stays on this phone.")
                }

                Section {
                    Toggle("Custom derivation path", isOn: $useCustomPath)
                    if useCustomPath {
                        TextField("m/44'/397'/0'/0'/1'", text: $pathText)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    if useCustomPath {
                        Text(customPathMessage)
                    } else {
                        Text("Uses \(book.nextStandardPath.description). Leave this off unless another wallet gave you a specific path.")
                    }
                }
            }
            .navigationTitle("New account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Add") { add() }
                            .disabled(path == nil)
                    }
                }
            }
            .interactiveDismissDisabled(working)
        }
    }

    private func add() {
        guard let path else { return }
        working = true
        Task { @MainActor in
            let added = await model.addAccount(name: name, path: path)
            working = false
            if added { dismiss() }
        }
    }
}
