import NearSignerCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var confirmErase = false
    @State private var confirmClear = false
    @State private var showGuide = false
    @State private var showWallets = false

    private var securityDone: Int { model.securityItems.filter(\.done).count }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle(isOn: Binding(get: { model.bluetoothEnabled }, set: { model.setBluetoothEnabled($0) })) {
                        Label("Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button {
                        showGuide = true
                    } label: {
                        Label("How to connect", systemImage: "questionmark.circle")
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Computers can find this phone only while NEAR Signer is open.")
                }

                Section {
                    Toggle(isOn: Binding(get: { model.appLockEnabled },
                                         set: { value in Task { await model.setAppLock(value) } })) {
                        Label("Lock app", systemImage: SecureKeyVault.biometrySymbol)
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Asks for \(SecureKeyVault.biometryName == "Passcode" ? "your passcode" : "\(SecureKeyVault.biometryName) or your passcode") each time you open NEAR Signer. Computers can't connect until it's unlocked.")
                }

                Section {
                    Button {
                        showWallets = true
                    } label: {
                        LabeledContent {
                            Text(String(model.wallets.wallets.count))
                        } label: {
                            Label("Wallets", systemImage: "wallet.pass")
                        }
                    }
                    .foregroundStyle(Color.primary)
                    NavigationLink {
                        SecurityView(model: model)
                    } label: {
                        LabeledContent {
                            Text("\(securityDone) of \(model.securityItems.count)")
                        } label: {
                            Label("Security checklist", systemImage: model.securityComplete ? "checkmark.shield" : "exclamationmark.shield")
                        }
                    }
                    NavigationLink {
                        AdvancedSettingsView(model: model)
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                    }
                }

                Section {
                    Button("Delete history", role: .destructive) { confirmClear = true }
                        .disabled(model.history.isEmpty)
                    Button("Remove all wallets from this phone", role: .destructive) { confirmErase = true }
                } footer: {
                    Text("Deletes every key from this phone. Wallets can be restored later from their recovery phrases. To remove a single wallet, use Wallets.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    LabeledContent("Works with", value: "Apps that support Ledger")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showGuide) { ConnectGuideView() }
            .sheet(isPresented: $showWallets) { WalletsView(model: model) }
            .alert("Remove all wallets?", isPresented: $confirmErase) {
                Button("Remove all", role: .destructive) { Task { await model.removeAllWallets() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Without every recovery phrase (or a copy of each imported key), the funds in these wallets are lost forever: nobody can recover them.")
            }
            .confirmationDialog("Delete all history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete history", role: .destructive) { model.clearHistory() }
            }
        }
    }
}

struct AdvancedSettingsView: View {
    let model: AppModel

    private var appVersion: String {
        NearAPDU.reportedAppVersion.map(String.init).joined(separator: ".")
    }

    var body: some View {
        Form {
            Section {
                Toggle("Require pairing", isOn: Binding(
                    get: { model.requirePairing }, set: { value in Task { await model.setRequirePairing(value) } }))
            } footer: {
                Text("Pairing encrypts the Bluetooth link. Turn it off only if your computer can't pair.")
            }

            Section {
                Toggle("Share known addresses automatically", isOn: Binding(
                    get: { model.autoSharePublicKeys }, set: { value in Task { await model.setAutoSharePublicKeys(value) } }))
            } footer: {
                Text("A computer asks before it gets an account's address for the first time. With this on, it can read that address again without asking. Signing always asks.")
            }

            Section {
                Toggle("Strict Face ID", isOn: Binding(
                    get: { model.strictBiometrics }, set: { value in Task { await model.setStrictBiometrics(value) } }))
            } footer: {
                Text("Only Face ID (no passcode) can sign or weaken security settings, so someone who learns your passcode can't use the wallet. The Secure Enclave enforces it, even after reinstalling the app. If the enrolled faces change, the wallets stop working for good: remove them and restore from their recovery phrases. Don't turn this on for an imported private key you have no copy of.")
            }

            Section("Compatibility") {
                LabeledContent("Bluetooth name", value: BLEPeripheral.localName)
                LabeledContent("Emulates", value: "Ledger Nano X")
                LabeledContent("NEAR app version", value: appVersion)
                #if targetEnvironment(simulator)
                LabeledContent("Simulator bridge", value: "127.0.0.1:\(SimulatorBridge.port)")
                #endif
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SecurityView: View {
    let model: AppModel

    var body: some View {
        List {
            Section {
                ForEach(model.securityItems) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(item.done ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.body.weight(.semibold))
                            Text(item.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Bluetooth keeps working in Airplane Mode. NEAR Signer never needs the internet. Deleting the app or turning off the iPhone passcode erases the keys on this phone: keep every recovery phrase.")
            }

            Section {
                TipRow(symbol: "lock.shield", title: "Turn on Lockdown Mode",
                       text: "Settings › Privacy & Security › Lockdown Mode.")
                TipRow(symbol: "icloud.slash", title: "Keep the phone to itself",
                       text: "Sign out of iCloud and remove apps you don't need.")
                TipRow(symbol: "hand.raised", title: "Use Guided Access",
                       text: "Keeps NEAR Signer on screen. Settings › Accessibility › Guided Access.")
            } header: {
                Text("For a Dedicated Signing Phone")
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TipRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }
}
