import CoreImage.CIFilterBuiltins
import NearSignerCore
import SwiftUI
import UIKit

// MARK: - Cards

extension View {
    /// Rounded card on the grouped background. Adapts to light and dark mode.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Liquid Glass

// On iOS 26 and later, controls that float above the content use Liquid Glass, as system bars
// and sheets do. Earlier systems keep the bordered buttons and opaque bars.
extension View {
    /// The main action of a screen or bar.
    @ViewBuilder
    func prominentActionStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// An action beside the main one.
    @ViewBuilder
    func secondaryActionStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// Pins buttons to the bottom edge. On iOS 26 and later they float over the content, which
    /// fades out beneath them like it does under the navigation bar; earlier, they sit on a bar.
    @ViewBuilder
    func bottomActionBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom) { content() }
        } else {
            safeAreaInset(edge: .bottom) { content().background(.bar) }
        }
    }

    /// A card that floats above the app like an alert: Liquid Glass on iOS 26 and later.
    @ViewBuilder
    func floatingPanel() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        } else {
            background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// Turns a request down: the Approve button's style in red, with white text.
struct RejectButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Reject").frame(maxWidth: .infinity)
        }
        .prominentActionStyle()
        .tint(.red)
    }
}

/// Closes a sheet: the system close button (an X) on iOS 26 and later, Done earlier.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(role: .close, action: action)
        } else {
            Button("Done", action: action)
        }
    }
}

// MARK: - Request rendering

/// Renders sections built by the core. Live approvals and history details use the same view,
/// so what the user approved can be reviewed later exactly as shown.
struct RequestSectionsView: View {
    let sections: [DisplaySection]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                SectionCard(section: section)
            }
        }
    }
}

struct SectionCard: View {
    let section: DisplaySection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DataText(section.title.trimmingCharacters(in: .whitespaces))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(section.fields.enumerated()), id: \.offset) { index, field in
                if index > 0 { Divider() }
                DisplayFieldView(field: field)
            }
        }
        .card()
        // Inner actions of a relayed meta-transaction are indented.
        .padding(.leading, section.title.hasPrefix("  ") ? 16 : 0)
    }
}

struct DisplayFieldView: View {
    let field: DisplayField

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            switch field.style {
            case .text:
                DataText(field.value)
                    .valueMenu(field.value, title: field.label)
            case .monospace:
                DataText(field.value)
                    .font(.callout.monospaced())
                    .valueMenu(field.value, title: field.label)
            case .amount:
                DataText(field.value)
                    .font(.title3.weight(.semibold))
                    .valueMenu(field.value, title: field.label)
            case .warning:
                DataText(field.value)
                    .font(.body.weight(.bold))
                    .foregroundStyle(.red)
            case .code:
                // Scrolls both ways: nothing in a long value is out of reach.
                ScrollView([.horizontal, .vertical]) {
                    Text(field.value)
                        .font(.footnote.monospaced())
                        .padding(10)
                }
                .frame(maxHeight: 280)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .valueMenu(field.value, title: field.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WarningCard: View {
    let text: String

    var body: some View {
        Label {
            DataText(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(Color.orange)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Badges

extension DisplaySymbol {
    var systemImage: String {
        switch self {
        case .send: return "arrow.up.right"
        case .call: return "curlybraces"
        case .createAccount: return "person.badge.plus"
        case .deploy: return "shippingbox.fill"
        case .stake: return "chart.line.uptrend.xyaxis"
        case .addKey: return "key.fill"
        case .deleteKey: return "key"
        case .deleteAccount: return "trash.fill"
        case .relay: return "arrow.triangle.2.circlepath"
        case .initialize: return "sparkles"
        case .gasKey: return "fuelpump.fill"
        case .message: return "signature"
        case .publicKey: return "person.crop.circle.badge.checkmark"
        case .multiple: return "list.bullet"
        case .swap: return "arrow.left.arrow.right"
        case .deposit: return "tray.and.arrow.down.fill"
        case .withdraw: return "tray.and.arrow.up.fill"
        case .dao: return "building.columns.fill"
        case .vote: return "hand.thumbsup.fill"
        }
    }
}

extension HistoryRecord.Kind {
    var label: String {
        switch self {
        case .transaction: return "Transaction"
        case .delegateAction: return "Meta-transaction"
        case .message: return "Message"
        case .publicKey: return "Address shared"
        }
    }

    /// Icon for records written before symbols were stored.
    var fallbackSymbol: DisplaySymbol {
        switch self {
        case .transaction: return .multiple
        case .delegateAction: return .relay
        case .message: return .message
        case .publicKey: return .publicKey
        }
    }
}

extension HistoryRecord {
    var displaySymbol: DisplaySymbol { symbol ?? kind.fallbackSymbol }
}

/// Icon in a tinted circle.
struct SymbolBadge: View {
    let symbol: DisplaySymbol
    var tint: Color = .accentColor
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol.systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}

struct NetworkBadge: View {
    let network: String

    private var tint: Color { network == "mainnet" ? .green : .orange }

    var body: some View {
        Text(network.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

extension HistoryRecord.Outcome {
    var label: String {
        switch self {
        case .approved: return "Signed"
        case .rejected: return "Rejected"
        case .failed: return "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .approved: return "checkmark.circle.fill"
        case .rejected: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .approved: return .green
        case .rejected: return .secondary
        case .failed: return .red
        }
    }
}

struct OutcomeBadge: View {
    let record: HistoryRecord

    private var text: String {
        record.kind == .publicKey && record.outcome == .approved ? "Shared" : record.outcome.label
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(record.outcome.color)
            .background(record.outcome.color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Accounts

/// Colored circle with the account number, so accounts are easy to tell apart.
struct AccountAvatar: View {
    let account: Account?
    var size: CGFloat = 40

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red]

    private var text: String {
        guard let account else { return "+" }
        if let index = account.index { return String(index) }
        return String(account.name.prefix(1)).uppercased()
    }

    private var color: Color {
        guard let account else { return .gray }
        let seed = Int(account.index ?? UInt32(account.publicKey.first ?? 0))
        return AccountAvatar.palette[seed % AccountAvatar.palette.count]
    }

    var body: some View {
        Text(text)
            .font(.system(size: size * (text.count > 2 ? 0.32 : 0.42), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Utilities

/// Request and account data. An id that wraps breaks at any character, without the hyphen iOS
/// would otherwise add (see `NearFormat.wrappingIDs`). VoiceOver reads the original text.
struct DataText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: NearFormat.wrappingIDs(text))
            .accessibilityLabel(text)
    }
}

struct CopyButton: View {
    let value: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}

/// Touch and hold a value to copy it or show it as a QR code. This phone is meant to stay
/// offline, so a QR code is how a value usually reaches another device.
struct ValueMenu: ViewModifier {
    /// Built only when used: a raw request can be megabytes.
    let value: () -> String
    let fitsQRCode: Bool
    let title: String
    @State private var showsQRCode = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = value() }
                if fitsQRCode {
                    Button("Show QR Code", systemImage: "qrcode") { showsQRCode = true }
                }
            }
            .sheet(isPresented: $showsQRCode) {
                QRCodeSheet(title: title, value: value())
            }
    }
}

extension View {
    /// See `ValueMenu`.
    func valueMenu(_ value: String, title: String) -> some View {
        modifier(ValueMenu(value: { value }, fitsQRCode: QRCode.fits(value), title: title))
    }
}

enum ValueMenuHint {
    static let text = "Touch and hold a value to copy it or show it as a QR code."
}

/// A value as a QR code, to scan with another device.
struct QRCodeSheet: View {
    let title: String
    let value: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    QRCodeView(value: value)
                        .frame(maxWidth: 320)
                    Text("Scan with another device's camera.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    DataText(value)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.center)
                        .lineLimit(12)
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CloseButton { dismiss() }
                }
            }
        }
    }
}

/// QR code on a white tile, so it scans in dark mode too.
struct QRCodeView: View {
    let value: String

    var body: some View {
        if let image = QRCode.image(for: value) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel("QR code")
        }
    }
}

enum QRCode {
    /// The most a QR code holds in byte mode at error correction level M (version 40).
    static let capacity = 2331

    static func fits(_ string: String) -> Bool { string.utf8.count <= capacity }

    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Number in a circle, for step-by-step instructions.
struct StepNumber: View {
    let number: Int

    var body: some View {
        Text(String(number))
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Color.accentColor, in: Circle())
            .accessibilityHidden(true)
    }
}
