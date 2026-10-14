import NearSignerCore
import SwiftUI

/// Lists the wallets (recovery phrases and imported keys). Tapping one makes it the wallet
/// computers connect to.
struct WalletsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Wallet?
    @State private var draftName = ""
    @State private var removing: Wallet?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.wallets.wallets) { wallet in
                        HStack(spacing: 12) {
                            Button {
                                model.setActiveWallet(wallet.id)
                                dismiss()
                            } label: {
                                WalletRow(wallet: wallet, isActive: wallet.id == model.activeWallet?.id)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.primary)

                            Menu {
                                Button("Rename", systemImage: "pencil") {
                                    draftName = wallet.name
                                    renaming = wallet
                                }
                                Button("Remove from this phone", systemImage: "trash", role: .destructive) {
                                    removing = wallet
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Options for \(wallet.name)")
                        }
                    }
                } footer: {
                    Text("Computers connect to the selected wallet. Each recovery phrase or private key is a separate wallet.")
                }

                Section {
                    NavigationLink {
                        AddWalletView(model: model, onFinished: { dismiss() })
                    } label: {
                        Label("Add wallet", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("Wallets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CloseButton { dismiss() }
                }
            }
            .alert("Rename wallet", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $draftName)
                Button("Save") {
                    if let wallet = renaming, !draftName.trimmingCharacters(in: .whitespaces).isEmpty {
                        model.renameWallet(wallet.id, to: draftName)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(removing.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            )) {
                Button("Remove", role: .destructive) {
                    guard let wallet = removing else { return }
                    Task {
                        if await !model.removeWallet(wallet.id) { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(removing?.kind == .privateKey
                    ? "The private key is deleted from this phone. Without a copy of it, the funds are lost forever: nobody can recover them."
                    : "Its key is deleted from this phone. Without the recovery phrase, the funds are lost forever: nobody can recover them.")
            }
        }
    }
}

struct WalletRow: View {
    let wallet: Wallet
    let isActive: Bool

    private var subtitle: String {
        let accounts = wallet.accounts.count == 1 ? "1 account" : "\(wallet.accounts.count) accounts"
        return wallet.kind == .recoveryPhrase ? "Recovery phrase · \(accounts)" : "Private key"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: wallet.kind == .recoveryPhrase ? "list.bullet.rectangle.portrait.fill" : "key.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(wallet.name)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isActive {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Selected")
            }
        }
        .padding(.vertical, 2)
    }
}

/// The three ways to add a wallet, reusing the onboarding screens.
struct AddWalletView: View {
    let model: AppModel
    let onFinished: () -> Void

    var body: some View {
        List {
            Section {
                NavigationLink {
                    CreateWalletView(model: model, onFinished: onFinished)
                } label: {
                    Label("Create a new wallet", systemImage: "sparkles")
                }
                NavigationLink {
                    RestoreWalletView(model: model, onFinished: onFinished)
                } label: {
                    Label("Restore with a recovery phrase", systemImage: "list.bullet.rectangle.portrait")
                }
                NavigationLink {
                    ImportKeyView(model: model, onFinished: onFinished)
                } label: {
                    Label("Import a private key", systemImage: "key")
                }
            } footer: {
                Text("Each wallet has its own accounts. You can switch between wallets at any time.")
            }
        }
        .navigationTitle("Add wallet")
        .navigationBarTitleDisplayMode(.inline)
    }
}
