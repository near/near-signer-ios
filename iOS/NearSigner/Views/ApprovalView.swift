import NearSignerCore
import SwiftUI

/// Full-screen review of an incoming request, shown by the overlay window. Approving hands control
/// back to the signer core, which then asks for Face ID / passcode before the key is decrypted.
struct ApprovalView: View {
    let model: AppModel
    let request: ApprovalRequest
    /// Approve ignores taps for a moment, so a tap already under way when the request appears
    /// cannot approve it.
    @State private var armed = false

    private var target: (wallet: Wallet?, account: Account?) { model.target(of: request) }

    private var account: Account? { target.account }

    private var accountName: String {
        account?.name ?? AccountBook.defaultName(for: request.path)
    }

    private var headline: String {
        guard request.kind == .publicKey else { return request.display.title }
        return account == nil ? "Connect \(accountName)?" : "Share \(accountName)?"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    accountCard
                    if let highlight = request.display.highlight {
                        HighlightCard(highlight: highlight, ownAccount: model.ownAccountLabel(for:))
                    }
                    if !request.display.extras.isEmpty {
                        SectionCard(section: DisplaySection(title: "Also in this request", fields: request.display.extras))
                    }
                    if !request.display.warnings.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(request.display.warnings, id: \.self) { warning in
                                WarningCard(text: warning)
                            }
                        }
                    }
                    if request.kind == .publicKey {
                        publicKeyExplanation
                    } else if request.display.highlight == nil {
                        RequestSectionsView(sections: request.display.primarySections)
                    }
                    TechnicalDetails(request: request)
                    Text("Approve only if you started this on your computer and everything above looks right.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .bottomActionBar { buttons }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            SymbolBadge(symbol: request.display.symbol, size: 64)
            DataText(headline)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let network = request.display.network {
                NetworkBadge(network: network)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var accountCard: some View {
        HStack(spacing: 12) {
            AccountAvatar(account: account)
            VStack(alignment: .leading, spacing: 2) {
                Text(accountCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DataText(accountName)
                    .font(.headline)
                if let signerId = request.signerId {
                    DataText(signerId)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let account {
                    DataText(account.shortDisplayAddress)
                        .font(account.accountId == nil ? .footnote.monospaced() : .footnote)
                        .foregroundStyle(.secondary)
                }
                if account == nil {
                    Text("New on this phone. It joins your accounts if you approve.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private var publicKeyExplanation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Your computer gets this account's address and public key.", systemImage: "eye")
            Label("That doesn't let it move funds. Every transaction still needs your approval here.",
                  systemImage: "hand.raised")
        }
        .font(.subheadline)
        .card()
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            RejectButton { model.resolve(request.id, approved: false) }
                .controlSize(.large)

            Button {
                model.resolve(request.id, approved: true)
            } label: {
                // The Face ID symbol only when Face ID (or the passcode) follows.
                Group {
                    if request.needsUnlock {
                        Label(approveTitle, systemImage: SecureKeyVault.biometrySymbol)
                    } else {
                        Text(approveTitle)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .prominentActionStyle()
            .controlSize(.large)
            .disabled(!armed)
        }
        .padding()
        .task {
            try? await Task.sleep(for: .seconds(1))
            armed = true
        }
    }

    private var approveTitle: String { request.kind == .publicKey ? "Share" : "Approve" }

    /// "Signing with", plus the wallet when there are several.
    private var accountCaption: String {
        let action = request.kind == .publicKey ? "Account" : "Signing with"
        guard model.wallets.wallets.count > 1, let wallet = target.wallet else { return action }
        return "\(action) · \(wallet.name)"
    }

    private var navigationTitle: String {
        switch request.kind {
        case .transaction: return "Review transaction"
        case .delegateAction: return "Review meta-transaction"
        case .message: return "Review message"
        case .publicKey: return "Account request"
        }
    }
}

/// Hashes, nonces, path: collapsed by default. When a card summarizes the request, every field
/// of it goes here too, so the screen shows the card and nothing it repeats.
private struct TechnicalDetails: View {
    let request: ApprovalRequest
    @State private var expanded = false

    private var summarized: Bool { request.display.highlight != nil }

    private var requestSection: DisplaySection {
        var fields = [
            DisplayField("Connection", request.transport),
            DisplayField("Received", request.receivedAt.formatted(date: .omitted, time: .standard)),
        ]
        if request.kind != .publicKey {
            fields.insert(DisplayField("Derivation path", request.path.description, style: .monospace), at: 0)
        }
        return DisplaySection(title: "Request", fields: fields)
    }

    var body: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack {
                    Text(summarized ? "Details" : "Technical details")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .card()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                RequestSectionsView(sections: (summarized ? request.display.primarySections : [])
                    + request.display.technicalSections + [requestSection])
                Text(ValueMenuHint.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }
}
