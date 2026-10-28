import NearSignerCore
import SwiftUI
import UIKit

struct HomeView: View {
    let model: AppModel
    @State private var sheet: Sheet?

    /// Opens a history entry. Account rows already navigate by plain UUID.
    private struct RecordLink: Hashable {
        let id: UUID
    }

    enum Sheet: String, Identifiable {
        case addAccount
        case guide
        case intro
        case scan
        case security
        case wallets

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ConnectionCard(state: model.connection,
                                   showGuide: { sheet = .guide },
                                   enableBluetooth: { model.setBluetoothEnabled(true) })
                    // Always offered, as its own row: it is how people who keep Bluetooth off use
                    // the app (README "Camera transfer").
                    Button {
                        model.startCameraTransfer()
                        sheet = .scan
                    } label: {
                        Label("Scan from computer", systemImage: "qrcode.viewfinder")
                    }
                }

                if let result = model.lastResult {
                    Section {
                        NavigationLink(value: RecordLink(id: result.id)) {
                            LastResultRow(record: result, onDismiss: { model.dismissLastResult() })
                        }
                    }
                }

                Section {
                    ForEach(model.accounts) { account in
                        NavigationLink(value: account.id) {
                            AccountRow(account: account)
                        }
                    }
                    if model.canAddAccounts {
                        Button {
                            sheet = .addAccount
                        } label: {
                            Label("Add account", systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    if model.accounts.isEmpty {
                        Text("Add Account 1 to see its address. You'll confirm with Face ID.")
                    } else if model.wallets.wallets.count > 1 {
                        Text("Computers connect to \(model.activeWallet?.name ?? "this wallet"). Tap the wallet button to switch.")
                    }
                }

                #if DEBUG
                Section {
                    Menu {
                        ForEach(AppModel.DemoRequest.allCases) { demo in
                            Button(demo.rawValue) { model.simulateIncomingRequest(demo) }
                        }
                    } label: {
                        Label("Simulate a request", systemImage: "wand.and.stars")
                    }
                } footer: {
                    Text("Debug builds only.")
                }
                #endif
            }
            .navigationTitle(model.activeWallet?.name ?? "NEAR Signer")
            .navigationDestination(for: UUID.self) { id in
                AccountDetailView(model: model, accountID: id)
            }
            .navigationDestination(for: RecordLink.self) { link in
                if let record = model.history.first(where: { $0.id == link.id })
                    ?? model.lastResult.flatMap({ $0.id == link.id ? $0 : nil }) {
                    HistoryDetailView(model: model, record: record)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        sheet = .wallets
                    } label: {
                        Image(systemName: "wallet.pass")
                    }
                    .accessibilityLabel("Wallets")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        sheet = .security
                    } label: {
                        Image(systemName: model.securityComplete ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(model.securityComplete ? Color.green : Color.orange)
                    }
                    .accessibilityLabel(model.securityComplete ? "Security: all set" : "Security: needs attention")

                    Button {
                        sheet = .guide
                    } label: {
                        ConnectionIcon(state: model.connection)
                    }
                    .accessibilityLabel(model.connection.title)
                }
            }
            .onChange(of: model.showConnectIntro, initial: true) { _, show in
                guard show else { return }
                model.showConnectIntro = false
                sheet = .intro
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .addAccount:
                    AddAccountView(model: model)
                case .wallets:
                    WalletsView(model: model)
                case .guide:
                    ConnectGuideView()
                case .intro:
                    ConnectIntroView()
                case .scan:
                    ScanView(model: model)
                case .security:
                    NavigationStack {
                        SecurityView(model: model)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    CloseButton { self.sheet = nil }
                                }
                            }
                    }
                }
            }
        }
    }
}

// MARK: - Connection

extension ConnectionState {
    var title: String {
        switch self {
        case .starting: return "Starting…"
        case .disabled: return "Bluetooth is off in NEAR Signer"
        case .needsPermission: return "Allow Bluetooth"
        case .bluetoothOff: return "Bluetooth is off"
        case .unsupported: return "Bluetooth unavailable"
        case .waiting: return "Ready to connect"
        case let .connected(count): return count == 1 ? "Computer connected" : "\(count) computers connected"
        case let .simulator(count): return count == 0 ? "Simulator mode" : "Test host connected"
        case .failed: return "Bluetooth problem"
        }
    }

    var message: String {
        switch self {
        case .starting: return "Getting Bluetooth ready."
        case .disabled: return "Computers can't reach this phone until you turn it on."
        case .needsPermission: return "NEAR Signer uses Bluetooth to talk to your computer."
        case .bluetoothOff: return "Turn on Bluetooth in Control Center. It works in Airplane Mode too."
        case .unsupported: return "This device can't act as a Bluetooth accessory."
        case .waiting: return "On your computer, open a NEAR app and choose Ledger. Keep this screen open."
        case .connected: return "Requests to sign will appear here."
        case .simulator: return "The Simulator has no Bluetooth. Test hosts on this Mac connect to 127.0.0.1:9999."
        case let .failed(message): return message
        }
    }

    var symbol: String {
        switch self {
        case .starting, .waiting: return "antenna.radiowaves.left.and.right"
        case .disabled, .needsPermission, .bluetoothOff, .unsupported: return "antenna.radiowaves.left.and.right.slash"
        case .connected: return "checkmark.circle.fill"
        case .simulator: return "desktopcomputer"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .starting, .disabled: return .secondary
        case .needsPermission, .bluetoothOff: return .orange
        case .unsupported, .failed: return .red
        case .waiting: return .accentColor
        case .connected: return .green
        case .simulator: return .purple
        }
    }
}

struct ConnectionIcon: View {
    let state: ConnectionState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.tint)
            .symbolEffect(.pulse, options: .repeating, isActive: state.isWaiting)
    }
}

struct ConnectionCard: View {
    let state: ConnectionState
    let showGuide: () -> Void
    let enableBluetooth: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ConnectionIcon(state: state)
                .font(.title2)
                .frame(width: 48, height: 48)
                .background(state.tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.headline)
                Text(state.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .needsPermission:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .disabled:
            Button("Turn On", action: enableBluetooth)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .waiting, .simulator:
            Button("How to connect", action: showGuide)
                .buttonStyle(.bordered)
                .controlSize(.small)
        default:
            EmptyView()
        }
    }
}

// MARK: - Rows

struct LastResultRow: View {
    let record: HistoryRecord
    let onDismiss: () -> Void

    private var headline: String {
        switch record.outcome {
        case .approved:
            return record.kind == .publicKey ? "Address shared with your computer" : "Signed and sent to your computer"
        case .rejected:
            return "Request rejected"
        case .failed:
            return "Request failed"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.outcome.symbol)
                .font(.title2)
                .foregroundStyle(record.outcome.color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                DataText(record.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if record.outcome == .failed, let reason = record.failureReason {
                    DataText(reason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
            }
            // Borderless, so the button keeps its own taps inside the row's NavigationLink.
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .accessibilityAction(named: "Dismiss", onDismiss)
    }
}

struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatar(account: account)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.body.weight(.semibold))
                if let accountId = account.accountId {
                    Text(accountId)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(account.shortAddress)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
