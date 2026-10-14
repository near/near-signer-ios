import NearSignerCore
import SwiftUI
import UIKit

/// Summary card for a recognized request: a token transfer, a swap or a DAO action.
struct HighlightCard: View {
    let highlight: Highlight
    /// "Account 2" when an account id is one of this phone's accounts.
    var ownAccount: @MainActor (String) -> String? = { _ in nil }

    var body: some View {
        switch highlight {
        case let .tokenMove(move):
            TokenMoveCard(move: move, ownAccount: ownAccount)
        case let .swap(swap):
            SwapCard(swap: swap)
        case let .dao(action):
            DAOCard(action: action)
        }
    }
}

/// The token's icon from the built-in list, or its first letter.
struct TokenIcon: View {
    let amount: TokenAmount
    var size: CGFloat = 44

    var body: some View {
        if let icon = amount.token?.icon {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text(String(amount.symbol.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.gray.gradient, in: Circle())
                .accessibilityHidden(true)
        }
    }
}

/// "1,000.5" large, with the symbol beside it.
struct TokenAmountText: View {
    let amount: TokenAmount
    var size: CGFloat = 34

    var body: some View {
        if amount.isKnown {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Never truncated: long amounts wrap instead.
                Text(amount.formatted)
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(amount.symbol)
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 4) {
                Text(amount.raw.description)
                    .font(.system(size: size * 0.7, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                DataText("units of \(amount.symbol)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Label("Unknown token", systemImage: "questionmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.orange)
            }
        }
    }
}

/// Who minted an internal NEAR Intents token, when the issuer isn't a trusted one. Anyone can
/// mint a token under any name, so the issuer is shown in full.
struct TokenIssuerText: View {
    let amount: TokenAmount
    var alignment: TextAlignment = .center

    var body: some View {
        if amount.hasUntrustedIssuer, let issuer = amount.issuer {
            DataText("Issued by \(issuer)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
                .valueMenu(issuer, title: "Token issuer")
        }
    }
}

private struct CardRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            DataText(value)
                .font(monospaced ? .callout.monospaced() : .callout.weight(.medium))
                .multilineTextAlignment(.trailing)
                .valueMenu(value, title: label)
        }
        .font(.callout)
    }
}

struct TokenMoveCard: View {
    let move: TokenMove
    var ownAccount: @MainActor (String) -> String? = { _ in nil }

    private var recipientLabel: String? {
        switch move.kind {
        case .send, .withdraw: return "To"
        case .deposit: return "Credited to"
        case .wrap, .unwrap: return nil
        }
    }

    private var received: String? {
        switch move.kind {
        case .wrap: return "\(move.amount.formatted) wNEAR"
        case .unwrap: return "\(move.amount.formatted) NEAR"
        default: return nil
        }
    }

    /// "Tether USD" under "5 USDt"; nothing when the name only repeats the symbol.
    private var tokenName: String? {
        guard let token = move.amount.token, token.name.caseInsensitiveCompare(token.symbol) != .orderedSame else { return nil }
        return token.name
    }

    private var isNearSend: Bool { move.kind == .send && move.amount.tokenId.isEmpty }

    private var hasDetails: Bool {
        received != nil || (recipientLabel == nil && move.counterparty != nil) || !(move.memo ?? "").isEmpty
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                TokenIcon(amount: move.amount, size: 56)
                TokenAmountText(amount: move.amount)
                if let tokenName {
                    Text(tokenName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TokenIssuerText(amount: move.amount)
                if let venue = move.venue {
                    Text(venue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .accessibilityElement(children: .combine)
            if let recipientLabel, let counterparty = move.counterparty {
                RecipientView(label: recipientLabel, accountId: counterparty, ownName: ownAccount(counterparty))
            }
            if hasDetails {
                Divider()
                VStack(spacing: 10) {
                    if let received {
                        CardRow(label: "You receive", value: received)
                    }
                    if recipientLabel == nil, let contract = move.counterparty {
                        CardRow(label: "Contract", value: contract, monospaced: true)
                    }
                    if let memo = move.memo, !memo.isEmpty {
                        CardRow(label: "Memo", value: memo)
                    }
                }
            }
            if isNearSend {
                Label("The recipient gets exactly \(move.amount.text). The network fee is paid on top.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 20)
    }
}

/// Who receives the funds: the full account id, what kind of account it is, and whether it is
/// one of this phone's own accounts.
struct RecipientView: View {
    let label: String
    let accountId: String
    /// "Account 2" when the recipient is one of this phone's accounts.
    let ownName: String?

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red]

    /// Implicit ids (64 hex characters, or `0x…`) are set in a fixed-width font.
    private var isImplicit: Bool { NearFormat.accountKind(accountId) != nil }

    /// Stable across launches (unlike `hashValue`), so the same account keeps its color.
    private var color: Color {
        let seed = accountId.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
        return RecipientView.palette[seed % RecipientView.palette.count]
    }

    private var badge: String {
        if accountId.hasPrefix("0x") || accountId.hasPrefix("0s") { return String(accountId.prefix(2)) }
        return String(accountId.prefix(1)).uppercased()
    }

    private var kind: String {
        switch NearFormat.accountKind(accountId) {
        case "implicit account": return "Implicit account (named by a public key). Created by the transfer if it doesn't exist yet."
        case "ETH-implicit account": return "Ethereum-style account on NEAR"
        case "deterministic account": return "Contract account (deterministic)"
        default: return "NEAR account"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                Text(badge)
                    .font(.system(size: badge.count > 1 ? 13 : 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(color.gradient, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    DataText(accountId)
                        .font(isImplicit ? .callout.monospaced().weight(.medium) : .title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .valueMenu(accountId, title: label)
                    if let ownName {
                        Label("Your account · \(ownName)", systemImage: "checkmark.seal.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.green)
                    } else {
                        Text(kind)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(accountId)")
        .accessibilityValue(ownName.map { "Your account, \($0)" } ?? kind)
    }
}

struct SwapCard: View {
    let swap: Swap

    var body: some View {
        VStack(spacing: 12) {
            SwapSide(title: "You pay", amounts: swap.give)
            Image(systemName: "arrow.down")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            SwapSide(title: "You receive", amounts: swap.receive)
            if let deadline = swap.deadline {
                Label("Valid until \(deadline)", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 20)
    }
}

private struct SwapSide: View {
    let title: String
    let amounts: [TokenAmount]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if amounts.isEmpty {
                Text("Nothing")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(amounts.enumerated()), id: \.offset) { _, amount in
                HStack(spacing: 12) {
                    TokenIcon(amount: amount, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        TokenAmountText(amount: amount, size: 24)
                        TokenIssuerText(amount: amount, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct DAOCard: View {
    let action: DAOAction

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "building.columns.fill")
                    .font(.title3)
                    .foregroundStyle(Color.indigo)
                    .frame(width: 44, height: 44)
                    .background(Color.indigo.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("DAO")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DataText(action.dao)
                        .font(.callout.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                        .valueMenu(action.dao, title: "DAO")
                }
            }
            Divider()
            switch action.kind {
            case let .propose(summary, description):
                Text("New proposal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                DataText(summary)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                ProposalDetails(sections: action.details)
                // What the proposal does comes first; the free-text description is all in Details.
                if !description.isEmpty {
                    DataText(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                if let bond = action.bond {
                    CardRow(label: "Bond", value: bond)
                }
            case let .vote(proposalId, vote, summary):
                HStack {
                    Text("Proposal #\(String(proposalId))")
                        .font(.headline)
                    Spacer()
                    VoteChip(vote: vote)
                }
                if let summary {
                    WebsiteClaim(proposalId: proposalId, summary: summary)
                    ProposalDetails(sections: action.details)
                }
            }
        }
        .card(padding: 20)
    }
}

/// What a vote's proposal does, as the website describes it, with a mark that opens the reason:
/// the vote names only the proposal number, and the phone can't look the proposal up.
private struct WebsiteClaim: View {
    let proposalId: UInt64
    let summary: String
    @State private var explained = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DataText(summary)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    withAnimation { explained.toggle() }
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Not verified")
                .accessibilityHint("Explains where this description comes from")
            }
            if explained {
                Text("This is how the website describes proposal #\(String(proposalId)). NEAR Signer can't check it offline.")
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A proposal's amounts, recipients and calls.
private struct ProposalDetails: View {
    let sections: [DisplaySection]

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
            VStack(alignment: .leading, spacing: 10) {
                let title = section.title.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    DataText(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(section.fields.enumerated()), id: \.offset) { _, field in
                    DisplayFieldView(field: field)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct VoteChip: View {
    let vote: String

    private var tint: Color {
        switch vote {
        case "Approve": return .green
        case "Reject": return .red
        case "Remove (spam)": return .orange
        default: return .gray
        }
    }

    private var symbol: String {
        switch vote {
        case "Approve": return "hand.thumbsup.fill"
        case "Reject": return "hand.thumbsdown.fill"
        default: return "checkmark.circle"
        }
    }

    var body: some View {
        Label(vote, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
