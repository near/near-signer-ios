import SwiftUI

/// Walkthrough for using NEAR Signer from websites. NEAR Signer stands in for a Ledger, so apps
/// connect through the Ledger option they already have. Shown after the first wallet is added,
/// and from How to connect.
struct ConnectIntroView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private static let pageCount = 4

    private var isLastPage: Bool { page == ConnectIntroView.pageCount - 1 }

    var body: some View {
        // A navigation bar, so Skip sits where the system puts sheet buttons.
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    // On every page, the last included: removing it collapses the bar and the
                    // whole page jumps up.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Skip") { dismiss() }
                    }
                }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                IntroPage(title: "Your iPhone works as a Ledger",
                          text: "NEAR apps already support Ledger. NEAR Signer stands in for one over Bluetooth.") {
                    LedgerStandInIllustration()
                }
                .tag(0)

                IntroPage(title: "Choose Ledger",
                          text: "On a NEAR website, tap Connect Wallet and pick Ledger. Use Chrome or Edge.") {
                    WalletPickerIllustration()
                }
                .tag(1)

                IntroPage(title: "Pick NEAR Signer",
                          text: "Choose it in your browser's Bluetooth list. Keep this app open.") {
                    BluetoothChooserIllustration()
                }
                .tag(2)

                IntroPage(title: "Approve on your phone",
                          text: "Check each request, then confirm with \(SecureKeyVault.biometryName).") {
                    ApprovalIllustration()
                }
                .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if isLastPage {
                    dismiss()
                } else {
                    withAnimation { page += 1 }
                }
            } label: {
                Text(isLastPage ? "Got it" : "Next")
                    .frame(maxWidth: .infinity)
            }
            .prominentActionStyle()
            .controlSize(.large)
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct IntroPage<Illustration: View>: View {
    let title: String
    let text: String
    @ViewBuilder let illustration: () -> Illustration

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                illustration()
                    .frame(maxWidth: 320)
                    .frame(minHeight: 220)
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text(title)
                        .font(.title2.bold())
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            // Room for the page dots.
            .padding(.bottom, 48)
        }
    }
}

// MARK: - Illustrations

/// This phone, linked over Bluetooth to a computer that thinks it is talking to a Ledger.
private struct LedgerStandInIllustration: View {
    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Computer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 8) {
                AppMark(size: 72)
                HStack(spacing: 6) {
                    LedgerDeviceShape()
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 24, height: 16)
                    Text("Acts as a Ledger")
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}

/// A website's wallet list with the Ledger entry picked out. The other entries are deliberately
/// blank: lists differ between sites, but every one that supports Ledger has this entry.
private struct WalletPickerIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect wallet")
                .font(.headline)
                .padding(.bottom, 2)
            ForEach(0..<2, id: \.self) { _ in placeholderRow }
            HStack(spacing: 12) {
                LedgerDeviceShape()
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 32, height: 32)
                Text("Ledger")
                    .font(.body.weight(.semibold))
                Spacer()
                Text("Choose this")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
            }
            placeholderRow
        }
        .card(padding: 16)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private var placeholderRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
                .frame(width: 32, height: 32)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
                .frame(width: 110, height: 12)
            Spacer()
        }
        .padding(10)
    }
}

/// The Ledger outline from near-cli-connect's signing-method picker, drawn on its 34×24 grid.
private struct LedgerDeviceShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 34, rect.height / 24)
        let origin = CGPoint(x: rect.midX - 17 * scale, y: rect.midY - 12 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        func roundedRect(_ path: inout Path, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat) {
            path.addRoundedRect(in: CGRect(origin: point(x, y), size: CGSize(width: width * scale, height: height * scale)),
                                cornerSize: CGSize(width: radius * scale, height: radius * scale), style: .circular)
        }
        var path = Path()
        // Body and screen.
        roundedRect(&path, 1, 5, 26, 14, radius: 3)
        roundedRect(&path, 4, 8, 10, 8, radius: 1.5)
        // The swivel cover on the right end.
        path.move(to: point(27, 9))
        path.addLine(to: point(31, 9))
        path.addArc(tangent1End: point(33, 9), tangent2End: point(33, 11), radius: 2 * scale)
        path.addLine(to: point(33, 13))
        path.addArc(tangent1End: point(33, 15), tangent2End: point(31, 15), radius: 2 * scale)
        path.addLine(to: point(27, 15))
        return path
    }
}

/// The browser's Bluetooth device chooser with NEAR Signer selected.
private struct BluetoothChooserIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The website wants to pair")
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "iphone")
                        .foregroundStyle(Color.accentColor)
                    Text(BLEPeripheral.localName)
                        .font(.body.weight(.semibold))
                    Spacer()
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.12))
                Divider()
                HStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(width: 90, height: 12)
                    Spacer()
                }
                .padding(12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(uiColor: .separator))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Spacer()
                Text("Pair")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .card(padding: 16)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

/// A miniature of the approval screen.
private struct ApprovalIllustration: View {
    var body: some View {
        VStack(spacing: 14) {
            Image("token-near")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
            VStack(spacing: 2) {
                Text("Send 1.5 NEAR")
                    .font(.title3.bold())
                Text("to bob.near")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // The approval screen's own button styles, so the picture matches it on every system.
            HStack(spacing: 10) {
                RejectButton {}

                Button {} label: {
                    Label("Approve", systemImage: SecureKeyVault.biometrySymbol)
                        .frame(maxWidth: .infinity)
                }
                .prominentActionStyle()
            }
            .font(.subheadline.weight(.semibold))
            // Part of the picture: taps fall through, and the page still swipes.
            .allowsHitTesting(false)
        }
        .card(padding: 18)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}
