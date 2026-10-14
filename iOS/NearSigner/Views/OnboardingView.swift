import Combine
import NearSignerCore
import SwiftUI
import UIKit

struct OnboardingView: View {
    let model: AppModel
    /// Re-evaluates the passcode check when the user comes back from the Settings app.
    @Environment(\.scenePhase) private var scenePhase

    enum Route: Hashable {
        case create
        case restore
        case importKey
    }

    private var needsPasscode: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return scenePhase == .active && !SecureKeyVault.deviceHasPasscode
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 14) {
                        AppMark(size: 88)
                            .padding(.top, 32)
                        Text("NEAR Signer")
                            .font(.largeTitle.bold())
                        Text("Use this iPhone as a hardware wallet for NEAR.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        FeatureRow(symbol: "lock.fill", title: "Your keys stay on this phone",
                                   text: "Sealed by the Secure Enclave and unlocked only with Face ID or your passcode.")
                        FeatureRow(symbol: "eye.fill", title: "See what you sign",
                                   text: "Every request is shown in plain words before you approve it.")
                        FeatureRow(symbol: "antenna.radiowaves.left.and.right", title: "Works like a Ledger",
                                   text: "Connects over Bluetooth to NEAR apps and tools that support Ledger.")
                    }

                    if needsPasscode {
                        Label("Set a passcode for this iPhone first, in the Settings app. NEAR Signer keeps keys only on passcode-protected devices.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.orange)
                            .card()
                    }

                    if !SecureKeyVault.usesSecureEnclave {
                        Text("Running without a Secure Enclave (iOS Simulator). Use test keys only.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .bottomActionBar {
                VStack(spacing: 12) {
                    NavigationLink(value: Route.create) {
                        Text("Create a new wallet")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .prominentActionStyle()
                    .controlSize(.large)

                    NavigationLink(value: Route.restore) {
                        Text("Restore with a recovery phrase")
                            .frame(maxWidth: .infinity)
                    }
                    .secondaryActionStyle()
                    .controlSize(.large)

                    NavigationLink("Import a private key", value: Route.importKey)
                        .font(.footnote)
                }
                .disabled(needsPasscode)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .create: CreateWalletView(model: model)
                case .restore: RestoreWalletView(model: model)
                case .importKey: ImportKeyView(model: model)
                }
            }
        }
    }
}

/// The one message about a recovery phrase that must not be missed.
struct NoRecoveryWarning: View {
    var subject = "these words"

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lose the words, lose the wallet")
                    .font(.headline)
                Text("If you lose \(subject), the wallet and all its funds are gone forever. Nobody can recover them: not NEAR Signer, not NEAR, not Apple. There is no reset, no support that can help, and no copy in iCloud.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.red.opacity(0.5))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Tracks screen recording / mirroring so the recovery phrase is not captured.
@MainActor
final class ScreenCaptureMonitor: ObservableObject {
    @Published private(set) var isCaptured = UIScreen.main.isCaptured
    private var observer: AnyCancellable?

    init() {
        observer = NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.isCaptured = UIScreen.main.isCaptured }
    }
}

// MARK: - Create

struct CreateWalletView: View {
    let model: AppModel
    /// Called after the wallet was added (closes the Add wallet sheet).
    var onFinished: () -> Void = {}

    enum Step {
        case intro
        case reveal
        case verify
    }

    struct Question: Identifiable {
        let position: Int
        let options: [String]
        var id: Int { position }
    }

    @State private var step: Step = .intro
    @State private var words: [String] = []
    @State private var questions: [Question] = []
    @State private var answers: [Int: String] = [:]
    @State private var wroteDown = false
    @State private var understandsLoss = false
    @StateObject private var capture = ScreenCaptureMonitor()

    private var allAnswered: Bool {
        !questions.isEmpty && questions.allSatisfy { answers[$0.position] != nil }
    }

    private var quizPassed: Bool {
        guard words.count == 24, !questions.isEmpty else { return false }
        return questions.allSatisfy { answers[$0.position] == words[$0.position] }
    }

    var body: some View {
        Group {
            switch step {
            case .intro: intro
            case .reveal: reveal
            case .verify: verify
            }
        }
        .navigationTitle("New wallet")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if words.isEmpty { generate() }
        }
    }

    // Step 1: explain what is coming.
    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "list.number")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                Text("Write down your recovery phrase")
                    .font(.title.bold())
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                NoRecoveryWarning(subject: "the 24 words")
                VStack(alignment: .leading, spacing: 18) {
                    FeatureRow(symbol: "pencil", title: "Use paper",
                               text: "You'll see 24 words. Write them down in order.")
                    FeatureRow(symbol: "key.fill", title: "The words are your wallet",
                               text: "If this phone is lost, broken or reset, the words are the only way to get your funds back.")
                    FeatureRow(symbol: "camera.fill", title: "No screenshots or photos",
                               text: "Anyone who sees the words can take your funds. Never type them into a website.")
                    FeatureRow(symbol: "trash", title: "This phone is not a backup",
                               text: "Deleting the app or turning off the iPhone passcode erases the key here. Only the words bring it back.")
                }
            }
            .padding(24)
        }
        .bottomActionBar {
            bottomButton("Show my recovery phrase", enabled: !words.isEmpty) { step = .reveal }
        }
    }

    // Step 2: show the words.
    private var reveal: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Write these 24 words on paper, in order.")
                    .font(.headline)
                NoRecoveryWarning()
                if capture.isCaptured {
                    Label("Screen recording or mirroring is on. Stop it to see the words.", systemImage: "eye.slash")
                        .foregroundStyle(Color.red)
                        .card()
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(word)
                                    .font(.body.monospaced())
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                Toggle("I wrote down all 24 words in order", isOn: $wroteDown)
                    .font(.subheadline)
                Toggle("I understand: if I lose these words, my funds are lost forever and nobody can recover them", isOn: $understandsLoss)
                    .font(.subheadline)
            }
            .padding(24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .bottomActionBar {
            bottomButton("Continue", enabled: wroteDown && understandsLoss) {
                answers = [:]
                step = .verify
            }
        }
    }

    // Step 3: check three words.
    private var verify: some View {
        ScrollView {
            if capture.isCaptured {
                Label("Screen recording or mirroring is on. Stop it to continue.", systemImage: "eye.slash")
                    .foregroundStyle(Color.red)
                    .card()
                    .padding(24)
            } else {
                verifyContent
            }
        }
        .bottomActionBar {
            bottomButton("Create wallet", enabled: quizPassed && !capture.isCaptured) { create() }
        }
    }

    private var verifyContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Check your backup")
                    .font(.title2.bold())
                Text("Tap the right word for each number, using your paper.")
                    .foregroundStyle(.secondary)
            }
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 10) {
                    Text("Word #\(question.position + 1)")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(question.options, id: \.self) { option in
                            WordChoice(word: option, selected: answers[question.position] == option) {
                                answers[question.position] = option
                            }
                        }
                    }
                }
            }
            if allAnswered && !quizPassed {
                Label("Some words don't match. Check your paper and try again.", systemImage: "xmark.circle.fill")
                    .foregroundStyle(Color.red)
                    .font(.subheadline)
            }
            Button("Show the words again") { step = .reveal }
                .font(.subheadline)
        }
        .padding(24)
    }

    private func bottomButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .prominentActionStyle()
        .controlSize(.large)
        .disabled(!enabled)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func generate() {
        guard let generated = try? BIP39.generateMnemonic(wordCount: 24), generated.count == 24 else {
            model.errorMessage = "Could not generate a recovery phrase."
            return
        }
        words = generated
        // Three positions; the other choices are words from the same phrase, so the order matters.
        let positions = Array(generated.indices.shuffled().prefix(3)).sorted()
        questions = positions.map { position in
            let correct = generated[position]
            let others = Array(Set(generated).subtracting([correct]).shuffled().prefix(3))
            return Question(position: position, options: (others + [correct]).shuffled())
        }
        answers = [:]
    }

    private func create() {
        do {
            // Keep the words if storing failed (for example, no device passcode).
            if model.addWallet(try KeyMaterial.fromMnemonic(words.joined(separator: " "))) {
                words = []
                questions = []
                answers = [:]
                onFinished()
            }
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

private struct WordChoice: View {
    let word: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(word)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Restore

struct RestoreWalletView: View {
    let model: AppModel
    var onFinished: () -> Void = {}
    @State private var phrase = ""
    @FocusState private var focused: Bool
    @StateObject private var capture = ScreenCaptureMonitor()

    private var status: (ok: Bool, text: String) {
        let words = BIP39.normalize(phrase)
        if words.isEmpty { return (false, "Enter your 12 or 24 words, separated by spaces.") }
        if let unknown = words.first(where: { !BIP39.isWord($0) }) {
            return (false, "\"\(unknown)\" isn't a recovery phrase word. Check the spelling.")
        }
        guard [12, 15, 18, 21, 24].contains(words.count) else { return (false, "\(words.count) words so far.") }
        do {
            _ = try BIP39.validate(words)
            return (true, "Valid \(words.count)-word phrase.")
        } catch {
            return (false, "These words don't form a valid phrase. Check the order and spelling.")
        }
    }

    var body: some View {
        Form {
            Section {
                if capture.isCaptured {
                    Label("Screen recording or mirroring is on. Stop it to enter your recovery phrase.", systemImage: "eye.slash")
                        .foregroundStyle(Color.red)
                } else {
                    TextEditor(text: $phrase)
                        .frame(minHeight: 150)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                        .focused($focused)
                }
            } header: {
                Text("Recovery Phrase")
            } footer: {
                Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(status.ok ? Color.green : Color.secondary)
            }

            Section {
                Button {
                    restore()
                } label: {
                    Text("Restore wallet")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .disabled(!status.ok)
            } footer: {
                Text("Use the phrase from your Ledger or another NEAR wallet. It never leaves this phone. Keep your paper copy: deleting the app, resetting the iPhone or turning off its passcode erases the key here, and without the phrase the funds are lost forever. Nobody can recover them.")
            }

            Section {
                DisclosureGroup("Phrase from near-cli-rs?") {
                    Text("Accounts that near-cli-rs creates from a phrase use the path m/44'/397'/0', which Ledger-compatible apps can't use. Import that account's private key instead, or add this phone's key to the account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Restore wallet")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func restore() {
        // Whatever the outcome (a typo, a duplicate wallet), the pasted phrase leaves the pasteboard.
        defer { Pasteboard.clearIfHolds(phrase) }
        do {
            if model.addWallet(try KeyMaterial.fromMnemonic(phrase)) {
                Pasteboard.clearIfHolds(phrase)
                phrase = ""
                onFinished()
            }
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

// MARK: - Private key

struct ImportKeyView: View {
    let model: AppModel
    var onFinished: () -> Void = {}
    @State private var secret = ""
    @StateObject private var capture = ScreenCaptureMonitor()

    var body: some View {
        Form {
            Section {
                if capture.isCaptured {
                    Label("Screen recording or mirroring is on. Stop it to enter the key.", systemImage: "eye.slash")
                        .foregroundStyle(Color.red)
                } else {
                    SecureField("ed25519:…", text: $secret)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } header: {
                Text("Private Key")
            } footer: {
                Text("For advanced users. A key from ~/.near-credentials or near-cli-rs export. An imported key is a wallet with a single account. Keep a copy: deleting the app, resetting the iPhone or turning off its passcode erases it here, and without a copy the funds are lost forever. Nobody can recover them.")
            }
            Section {
                Button {
                    importKey()
                } label: {
                    Text("Import key")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .disabled(secret.isEmpty)
            }
        }
        .navigationTitle("Import private key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func importKey() {
        // Whatever the outcome (a typo, a duplicate wallet), the pasted key leaves the pasteboard.
        defer { Pasteboard.clearIfHolds(secret) }
        do {
            if model.addWallet(try KeyMaterial.fromNearSecretKey(secret)) {
                Pasteboard.clearIfHolds(secret)
                secret = ""
                onFinished()
            }
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

/// Clears the pasteboard if it still holds a secret the user pasted in. Case and spacing are
/// ignored, so a phrase copied with capitals or line breaks still matches.
enum Pasteboard {
    static func clearIfHolds(_ secret: String) {
        let secret = normalized(secret)
        guard !secret.isEmpty, UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string else { return }
        let held = normalized(text)
        // Part of the secret counts too (a few words copied at a time), but not a lone short word.
        guard held.contains(secret) || (held.count >= 8 && secret.contains(held)) else { return }
        UIPasteboard.general.items = []
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
