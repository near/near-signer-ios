import NearSignerCore
import SwiftUI

/// Makes a Secure Enclave key wallet: an ML-DSA-65 key the Secure Enclave generates and keeps, with no
/// recovery phrase. Says what that means before the key exists.
struct QuantumWalletView: View {
    let model: AppModel
    /// Called after the wallet was added (closes the Add wallet sheet).
    var onFinished: () -> Void = {}

    @State private var understandsNoPhrase = false
    @State private var understandsCamera = false
    @State private var creating = false

    /// ML-DSA-65 in the Secure Enclave came with iOS 26; older systems can read about it only.
    private let supported = SecureKeyVault.supportsQuantumSafeKeys

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                Text("A quantum-safe key that never leaves the chip")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                if !supported {
                    WarningCard(text: "Secure Enclave keys need iOS 26 or newer. Update this iPhone to create one; recovery-phrase and imported-key wallets work as before.")
                }
                Text("Your recovery phrase already gives you a quantum-safe account that the phrase backs up. This key is for people who want one with no backup at all, held by the hardware.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 16) {
                    point("cpu", "Made in the Secure Enclave",
                          "The phone's security chip generates an ML-DSA-65 key and keeps it. The key never leaves the chip, not even to this app: signing happens inside it, after \(SecureKeyVault.biometryName).")
                    point("person.text.rectangle", "Its own NEAR account",
                          "The key comes with a universal account (an address starting with 0u). Send NEAR to the address to create the account; its first transaction, signed here, activates it. On an existing account, add the public key as an access key instead.")
                    point("antenna.radiowaves.left.and.right", "Bluetooth and camera",
                          "Computers reach it over Bluetooth or with QR codes (Scan from computer), like any account here. Apps and tools that only know Ledger keys can't use it.")
                    point("exclamationmark.triangle", "No recovery phrase",
                          "There is nothing to write down and nothing to export. If this phone is lost, reset or replaced, the key is gone with it. Keep another key on any account that matters.")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $understandsNoPhrase) {
                        Text("I understand this key exists only in this phone's Secure Enclave and has no recovery phrase.")
                            .font(.subheadline)
                    }
                    Toggle(isOn: $understandsCamera) {
                        Text("I understand that losing this phone loses this key, and that no one can recover it.")
                            .font(.subheadline)
                    }
                }
                .toggleStyle(CheckboxToggleStyle())
                #if targetEnvironment(simulator)
                Text("The iOS Simulator has no Secure Enclave: a software key stands in. Use test funds only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #endif
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .navigationTitle("Secure Enclave key")
        .navigationBarTitleDisplayMode(.inline)
        .bottomActionBar {
            Button {
                create()
            } label: {
                Text("Create Secure Enclave key")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .prominentActionStyle()
            .controlSize(.large)
            .disabled(!supported || !understandsNoPhrase || !understandsCamera || creating)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func create() {
        creating = true
        defer { creating = false }
        if model.addQuantumSafeWallet() { onFinished() }
    }
}

/// A toggle drawn as a checkbox with its label beside it.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                configuration.label
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }
}
