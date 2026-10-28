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

    private let cliQrExample = """
        near tokens alice.near send-near bob.near '1 NEAR' \\
          network-config mainnet sign-with-near-signer-qr \\
          --seed-phrase-hd-path "44'/397'/0'/0'/1'" send
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
                    GuideStep(number: 1, title: "Show the request as codes",
                              text: "On your computer, choose \"NEAR Signer\" in a wallet list, or use the NEAR Signer QR tool or its web page. It shows the request as a loop of QR codes.")
                    GuideStep(number: 2, title: "Tap Scan from computer",
                              text: "Point this phone's camera at the codes until the request appears. Check it, then approve with Face ID.")
                    GuideStep(number: 3, title: "Show the answer back",
                              text: "The phone shows one QR code. Hold it up to your computer's camera, or type the letters under it.")
                } header: {
                    Text("Without Bluetooth")
                } footer: {
                    Text("The camera only takes pictures in, so the computer can't reach anything on this phone.")
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
                        Text("Without Bluetooth, a near-cli-rs with sign-with-near-signer-qr shows the codes in the terminal and takes the answer typed:")
                            .font(.subheadline)
                        Text(cliQrExample)
                            .font(.caption.monospaced())
                            .valueMenu(cliQrExample, title: "near-cli-rs example (QR codes)")
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
