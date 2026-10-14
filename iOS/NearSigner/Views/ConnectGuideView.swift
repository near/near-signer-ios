import SwiftUI

/// Plain-language steps for connecting a computer, with the command-line details tucked away.
struct ConnectGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showIntro = false

    private let cliExample = """
        near tokens alice.near send-near bob.near '1 NEAR' \\
          network-config mainnet sign-with-ledger \\
          --seed-phrase-hd-path "44'/397'/0'/0'/1'" bluetooth send
        """

    var body: some View {
        NavigationStack {
            List {
                Section {
                    GuideStep(number: 1, title: "Keep NEAR Signer open",
                              text: "Your computer can find this phone only while the app is on screen.")
                    GuideStep(number: 2, title: "On your computer, choose Ledger",
                              text: "Open a NEAR website in Chrome or Edge, tap Connect Wallet and pick Ledger. NEAR Signer works as a Ledger, so you don't need a real one.")
                    GuideStep(number: 3, title: "Choose \"NEAR Signer\"",
                              text: "It appears in the list of Bluetooth devices. If you're asked to pair, check that the code matches on both screens.")
                    GuideStep(number: 4, title: "Approve on this phone",
                              text: "Check what you're signing, then confirm with Face ID.")
                } header: {
                    Text("Connect a Computer")
                } footer: {
                    Button("Show the walkthrough") { showIntro = true }
                        .font(.footnote.weight(.semibold))
                        .padding(.top, 4)
                }

                Section {
                    Text("Account 1 is what apps use by default. To use another account, enter its number where the app asks for a Ledger account or path. Account N uses the path 44'/397'/0'/0'/N'.")
                        .font(.subheadline)
                } header: {
                    Text("More Than One Account")
                }

                Section {
                    Text("Safari and Firefox can't use Bluetooth. On Linux, Chrome needs Web Bluetooth turned on in chrome://flags.")
                        .font(.subheadline)
                } header: {
                    Text("Browsers")
                }

                Section {
                    DisclosureGroup("near-cli-rs") {
                        Text("near-cli-rs 0.25 or newer supports Bluetooth Ledgers. Choose sign-with-ledger, then bluetooth.")
                            .font(.subheadline)
                        Text(cliExample)
                            .font(.caption.monospaced())
                            .valueMenu(cliExample, title: "near-cli-rs example")
                        Text(ValueMenuHint.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Command Line")
                }

                #if targetEnvironment(simulator)
                Section {
                    Text("The Simulator has no Bluetooth. Send requests from the Mac instead:")
                        .font(.subheadline)
                    Text("near-signer-host --tcp 127.0.0.1:9999 pubkey")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Simulator")
                }
                #endif
            }
            .sheet(isPresented: $showIntro) { ConnectIntroView() }
            .navigationTitle("How to connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    CloseButton { dismiss() }
                }
            }
        }
    }
}

private struct GuideStep: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StepNumber(number: number)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
