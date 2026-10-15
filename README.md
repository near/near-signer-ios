# NEAR Signer: an iPhone as a NEAR hardware wallet

NEAR Signer turns an iPhone into a locked-down signing device, used the way you would use a Ledger:

```
 near-cli-rs ──────┐  Bluetooth LE (Ledger Nano X GATT profile, Ledger BLE framing)
 near-connect dapp ┼──────────────────────────────────────────────┐
 (Chrome / Edge)   │                                              ▼
 near-signer-host ─┘                                   ┌──────────────────────┐
 (--ble, any tool)                                     │  NEAR Signer (iOS)   │
                                                       │  decode → review →   │
                                                       │  Face ID → ed25519   │
                                                       └──────────────────────┘
```

The phone speaks the NEAR Ledger app's APDU protocol. Hosts that already support a Ledger over
Bluetooth work without changes:

- **near-cli-rs 0.25 or newer**: `sign-with-ledger … bluetooth`. The prebuilt release binaries
  include Bluetooth support.
- **near-connect**: its existing Ledger wallet connects over Web Bluetooth in Chrome or Edge.

For each request the phone:

1. Fully decodes the transaction. It never signs bytes it cannot decode, so there is no blind signing.
2. Shows every field, with warnings for risky actions such as full-access keys or account deletion.
3. Signs only after you approve and then pass Face ID or enter the passcode.
4. Records the request in a signing history, whether you approved it, rejected it, or it failed.

The app is built for people who are not developers:

- **Wallets and accounts.** The phone holds several wallets (recovery phrases or imported
  private keys). A recovery phrase holds many accounts, like a Ledger: Account N uses the path
  `m/44'/397'/0'/0'/N'`, the same numbering NEAR wallets use for Ledger accounts.
- **Named accounts.** An account can carry its NEAR account name (alice.near). You type it in, or
  confirm a suggestion seen in requests you approved. Lists, QR codes and approvals then show it.
- **Readable requests.** Common operations get a summary card with token icons: NEAR transfers,
  token transfers (NEP-141), wrapping NEAR, Sputnik DAO proposals and votes, and NEAR Intents (deposits,
  withdrawals, swaps and other signed intents). Every field stays available below the card.
- **Connect walkthrough.** After the first wallet is added, a short walkthrough explains that
  NEAR Signer works as a Ledger: on a NEAR website, choose Ledger in the wallet list, then pick
  NEAR Signer in the browser's Bluetooth list. How to connect can show it again.
- **Plain language first.** The home screen shows the connection as one icon and one sentence,
  with a button for the next step (turn on Bluetooth, allow access, how to connect). Derivation
  paths, hashes and protocol details sit behind "Advanced" and "Technical details".
- **Values leave by QR code.** Touch and hold any value (account ids, hashes, signatures,
  arguments, the raw request) to copy it or show it as a QR code for another device's camera;
  the phone is meant to stay offline, so there are no copy buttons on their own. Values longer
  than a QR code holds (2 331 bytes) can only be copied.
- **Light and dark mode.** The app follows the system setting by default. Settings › Appearance
  can force light or dark.
- **App lock.** Like a banking app, NEAR Signer opens on a lock screen and asks for Face ID by
  itself (with the passcode as fallback). "Use Passcode" opens it with the passcode alone, without
  scanning a face, and the lock screen remembers that choice. It locks again whenever you leave
  it. Settings › Security › Lock app turns it off.

## Can an iPhone do this? (Apple platform constraints)

| Channel | Possible? | Notes |
|---|---|---|
| **Bluetooth LE (GATT)** | **Yes** | `CBPeripheralManager` lets an app act as a GATT peripheral with custom services. Arbitrary bytes travel through write and notify characteristics. Desktop hosts can discover the phone only while the app is in the foreground; in the background iOS hides the service UUIDs. This app runs its transports in the foreground only, on purpose. |
| Classic Bluetooth (RFCOMM/SPP) | No | There is no public API for it. It requires MFi / External Accessory. |
| USB as a USB device (HID/CDC) | No | iOS apps cannot act as a USB gadget, so a phone can never look like a USB Ledger. |
| USB through usbmuxd | Not supported | Technically possible: an app can listen on loopback and a computer can reach it over the cable with `iproxy`. But every host would need that helper running, and neither near-cli-rs nor browsers can use it. The app therefore supports Bluetooth only. |
| Web browsers | Chrome/Edge: yes | Web Bluetooth works in Chrome and Edge on macOS, Windows, ChromeOS and Android. On Linux it needs a flag. Safari and Firefox have no Web Bluetooth. |
| iOS Simulator | No Bluetooth | The Simulator has no Bluetooth. Simulator builds (only) add a test bridge on `127.0.0.1:9999`, so the app can be driven from the Mac. Device builds do not contain it. |
| Secure Enclave | P-256 only | The Secure Enclave cannot hold an ed25519 key. The ed25519 secret is encrypted to a Secure Enclave P-256 key instead (see [Security model](#security-model)). |

## Repository layout

```
Package.swift                 Swift package: NearSignerCore (iOS/macOS/Linux) + near-signer-sim
Sources/NearSignerCore/       all protocol and signing logic, shared by the app and the simulator
  Borsh/, Encoding/           Borsh reader/writer, Base58, u128
  Near/Types.swift            nearcore types: every Action 0–15, TransactionV0/V1, DelegateAction(V2),
                              NEP-413 payload, signing digests
  Near/Display.swift          human-readable rendering and risk warnings (one source of truth for UIs)
  Crypto/                     BIP-39, SLIP-10 ed25519, key import (seed phrase, ed25519:… key)
  Protocol/                   APDUs, NEAR Ledger app emulation, Ledger BLE framing, Speculos TCP framing
  Signer/SignerService.swift  decode → approve → unlock → sign → record history
  Accounts/                   wallets, accounts (derivation paths, named accounts), routing
  Near/Apps.swift, Tokens.swift  token transfers, DAO, NEAR Intents recognition; token list
  History/History.swift       signing history store (JSON, file protection on iOS)
Sources/near-signer-sim/      the same core as a desktop "device" served over TCP (macOS/Linux)
Tests/NearSignerCoreTests/    100 unit/integration tests, fixtures generated by near-api-js
iOS/NearSigner.xcodeproj      the iOS app (Xcode 26+); iOS/project.yml is an XcodeGen fallback
iOS/NearSigner/               SwiftUI app: Secure Enclave key vault, CoreBluetooth peripheral,
                              accounts, approval screen, history, settings, onboarding
host/python/                  near-signer-host CLI (stdlib only; `bleak` for Bluetooth) + e2e tests
host/compat/                  runs near-connect's real Ledger executor against the simulator
scripts/                      test-all.sh, format.sh, fixture regeneration, app icon generator
                              (NEAR symbol from the near.org site header), token icon renderer
.github/                      CI workflows (GitHub Actions) and Dependabot settings
```

## Protocol

**APDUs**: the NEAR Ledger app protocol, as implemented by LedgerHQ/app-near and used by
near-ledger-rs and near-connect:

| CLA INS | Command | Data |
|---|---|---|
| `80 06` | get version | → `02 04 03` (reported as 2.4.3, so hosts enable every feature) |
| `80 04` | get public key (P1 `00` display / `01` silent) | 20-byte path (5 × u32 BE, hardened) → 32-byte key |
| `80 05` | get wallet id | same as the public key |
| `80 02` | sign transaction | path ‖ `borsh(Transaction)`, 250-byte chunks, P1 `80` on the last → 64-byte signature |
| `80 07` | sign NEP-413 message | path ‖ `borsh(Payload)` (without the 2³¹+413 tag) |
| `80 08` | sign NEP-366 delegate action | path ‖ `borsh(DelegateAction)` (without the 2³⁰+366 prefix) |
| `B0 01`, `E0 D8`, `B0 A7` | BOLOS get app name / open app / quit app | reports "NEAR"; after quit app, "BOLOS" (the dashboard) until open app or the next `80` command |
| `E0 01` | BOLOS firmware details | on the dashboard `6A81`, and NEAR is open again; inside NEAR `6E00`, as on a Ledger |
| `80 20` | NEAR Signer only: fast-mode capabilities | → `"NS"`, version, flags, max chunk (u32 BE); a Ledger answers `6D00` |

Status words: `9000` OK, `6985` rejected by the user, `B005` payload could not be decoded
(refused), `B00B` bad path, `B00D` the transaction's key is not this device's key at that path,
`5515` no key, `6601` busy, `6A81` no firmware details.

Ledger Live's device manager (My Ledger, also opened right after adding a device) cannot work with
NEAR Signer: it needs firmware details and Ledger's genuine-device check. It sends quit app until it
sees the dashboard, then asks for firmware details; the `6A81` answer ends it with an error instead
of a spinner that never stops. Adding NEAR accounts and signing in Ledger Live don't use it.

**Fast mode**: the Ledger protocol sends 250-byte chunks and waits for a reply to each, which makes
a 1 MB deployment take minutes over Bluetooth. Hosts that get an answer to `80 20` may send signing
payloads as extended APDUs (`CLA INS P1 P2 00 Lc_hi Lc_lo data`) of up to 32 KiB, and write long BLE
messages without a response per packet (one acknowledged write every 4 packets, and the last
packet of every message acknowledged). `near-signer-host` does this automatically (`--no-fast`
turns it off). Other hosts, such as near-cli-rs and near-connect, use the standard protocol, as
they do with a Ledger.

**Bluetooth**: Ledger Nano X service `13d63400-2c97-0004-0000-4c6564676572`, with notify `…0001…`,
write `…0002…` and write-without-response `…0003…`. Packets use Ledger framing
`05 | seq u16 | [len u16] | data`. The MTU probe `08 00 00 00 00` is answered with the packet size.

**TCP (near-signer-sim and the Simulator test bridge)**: Speculos framing. A request is `u32 BE length ‖ APDU`. A
response is `u32 BE length(data) ‖ data ‖ SW`.

**Decoding coverage**: TransactionV0 and V1 (gas-key nonces, nonce mode), and all 16 actions of
current nearcore:

- CreateAccount, DeployContract, FunctionCall, Transfer, Stake, AddKey (including gas-key permissions), DeleteKey, DeleteAccount
- Delegate, DeployGlobalContract, UseGlobalContract, DeterministicStateInit
- TransferToGasKey, WithdrawFromGasKey, DelegateV2, UniversalStateInit

It also decodes NEP-366 delegate actions and NEP-413 messages. Ed25519, secp256k1 and ML-DSA-65
public keys are decoded and displayed, but the device itself signs with ed25519.

## Security model

- **Key storage.** The ed25519 secret (a BIP-39 seed or a single imported key) is encrypted with
  ECDH, HKDF-SHA256 and AES-GCM to a Secure Enclave P-256 key, created with
  `[.privateKeyUsage, .userPresence]`, or `[.privateKeyUsage, .biometryCurrentSet]` with Strict
  Face ID. Each wallet is one keychain item holding the enclave key's handle and the wrapped
  secret, so switching Strict Face ID on or off replaces both in one atomic update.
  - The keychain items are `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`.
  - They are never backed up and never synced to iCloud.
  - They are destroyed if the device passcode is removed.
  - The secret is decrypted only after Face ID or the passcode, for one signature, and then dropped.
- **Trusted display.** The phone renders the request from the exact bytes it signs. A compromised
  computer can send a different transaction, but it cannot make the phone show something other
  than what will be signed.
- **No blind signing.** Unknown actions or trailing bytes are refused with `B005` and recorded in the history.
  Decoding is strict: strings must be exact UTF-8 (a hidden byte-order mark is refused), at most
  100 actions are accepted (nearcore's limit), and the decoded request must re-encode to exactly
  the signed bytes.
- **What you see is what you sign.** Invisible and layout-changing characters (controls, bidi
  overrides, zero-width, fillers, variation selectors, unusual spaces) are shown as `\u{…}`.
  Summary cards are built only when every amount parses exactly as the contract reads it
  (including Rust's optional `+`) and the JSON, including JSON nested in a `msg` or a DAO
  proposal's call, has no duplicate keys and fits on screen; otherwise the raw request is shown
  with a warning. A summary card keeps every warning the raw view would show. Unknown fields in NEAR Intents
  are listed with a warning, and all attached NEAR stays in plain sight. Amounts are never
  truncated, and thousands are grouped with a narrow space, which no locale reads as a decimal point.
  Account ids, keys and token ids that wrap break at any character: iOS 26 would otherwise hyphenate
  them and show a "-" they don't have. Copying gives the exact value.
- **NEAR keys only.** Paths must be 5 hardened levels under `44'/397'`, so a host cannot use the
  seed's keys for other chains.
- **Key check.** If the transaction's `public_key` is not this device's key at the requested path,
  the request is refused with `B00D`. Signing it would be useless anyway. A failed check does not
  count as sharing that path's public key.
- **Bluetooth pairing.** It is required by default. As on a Nano X, subscribing to notifications
  triggers pairing, and writes are accepted only on the encrypted link. Ledger's mobile transports
  (Ledger Live, Meteor) send their first packet, the MTU probe, as a write without response right
  after subscribing. On a first connection it can arrive before pairing finishes and is then
  dropped without an error, so a computer that has sent nothing a second after subscribing gets
  the probe's answer (the packet size) anyway.
- **App lock.** On by default once a wallet exists. The lock screen sits in the window above the
  app, so it also covers a sheet that was open when the app was left, and the app locks whenever
  it goes to the background. Bluetooth starts only after unlocking, so computers can't reach a
  locked app. "Use Passcode" evaluates an access control that requires the device passcode
  (`.devicePasscode`; LocalAuthentication has no passcode-only policy), so no face is scanned.
  Unlocking accepts Face ID or the passcode even with Strict Face ID: the passcode
  must always open the app, so wallets whose strict keys stopped working can be removed and
  restored. Signing still asks again, and under Strict Face ID only Face ID signs. Turning the
  lock off counts as weakening security (Face ID only while any key is strict).
- **Bluetooth only, foreground only.** Device builds have no other transport. Bluetooth runs only
  while the app is in the foreground. Going to the background stops it and rejects any pending
  prompt. Cancelling Face ID counts as a rejection. Only computers that subscribed to
  notifications get a connection, each labelled on screen ("Bluetooth · 3F2A"). The Approve
  button ignores taps for a second after a request appears. Sharing an account the phone already
  has takes only that tap, because its public key is stored; its Share button has no Face ID symbol.
- **Face ID for anything destructive.** Removing or restoring wallets, turning off pairing or
  turning on automatic address sharing needs Face ID or the passcode. **Strict Face ID**
  (Settings › Advanced) removes the passcode fallback for signing and for weakening settings, so
  someone who learned the passcode cannot sign. The Secure Enclave enforces it
  (`.biometryCurrentSet`), and the setting is stored with each key, so reinstalling the app does
  not lift it. While any key on the phone is strict (an earlier installation's included),
  weakening settings needs Face ID too. Enrolling a new face (which the passcode allows) makes
  those keys unusable for good: remove the wallets (the passcode still works for that) and
  restore them from their recovery phrases. Strict Face ID turned on in an earlier version stays
  enforced by the app until the user confirms the one-time key update it offers.
- **Recovery phrase generation.** 256 bits from the system's cryptographically secure generator
  (`SecRandomCopyBytes`, whose status is checked), never a seeded or time-based PRNG. Output only a
  broken generator produces (all one byte value, or the same bytes twice in a row) stops the
  setup. The new phrase is decoded again and must give back the same entropy. Tests check the
  Trezor BIP-39 vectors, which were also recomputed independently in Python. Before moving on from
  the words, the user has to confirm they understand that losing them loses the wallet for good.
- **Typing secrets.** Third-party keyboards are disabled app-wide, recovery-phrase and key inputs
  are hidden while the screen is recorded or mirrored, and a pasted secret is cleared from the
  pasteboard after import, or when the screen is left. Clearing doesn't read the pasteboard, so
  iOS asks no paste permission. Secrets are held in memory that is wiped when released (best effort).
- **iPhone only.** The app does not run on iPad or Mac, where the privacy overlay and
  screen-capture detection are not reliable. Devices without a Secure Enclave are refused.
- **Always on top.** Approval requests, the lock screen, errors and the privacy shield are shown in a separate
  window above the app, so an open sheet, alert or share sheet can never hide a request.
- **Privacy screen.** The shield hides the UI in the app switcher and during Face ID. It shows the
  app icon (light or dark, following the app's appearance), like the lock screen. The
  recovery phrase is hidden while the screen is being recorded or mirrored.
- **Keys are never deleted silently.** Keychain items survive deleting the app. Each secret is
  tagged with an install id kept in UserDefaults, which an uninstall wipes. After a reinstall the
  app asks whether to restore or delete the wallets it finds. A secret of this install missing
  from the list (a lost or damaged file, which is kept aside) comes back as "Recovered wallet". A
  wallet leaves the list only after its keychain items were really deleted. The wallet list is
  excluded from backups, because the keys are this-device-only. Keys from earlier single-wallet
  builds are moved into the wallet list, and the old items are deleted only after the move is saved.
- **History and wallets.** Both files are stored with `.completeFileProtection`, so they are
  unreadable while the phone is locked. Requests refused without a prompt keep only their hash and
  size, raw payloads are kept up to 16 MB in total, and when the history is full, refusals are
  dropped before approved signatures, so a hostile host cannot flush the record of what was signed.
  Neither holds a secret. Both are excluded from iCloud and computer backups, because the history
  keeps signed requests, NEP-413 sign-in messages included. The app waits until the phone is
  unlocked before reading them (iOS may launch apps early), instead of acting on an
  empty list.
- **One Secure Enclave key per wallet.** Each wallet's secret is wrapped by its own Secure
  Enclave key. Removing a wallet deletes both.
- **Recommended "full lockdown" setup** for a dedicated phone:
  - Airplane Mode with Bluetooth turned back on.
  - Lockdown Mode. NEAR Signer uses none of what it restricts: no web content or web fonts, no
    wired accessories, no internet, no configuration profiles. Bluetooth, the keychain, the Secure
    Enclave and Face ID are not affected by it.
  - No iCloud account.
  - Guided Access, to pin the app.

  The app's settings show a checklist.

## Wallets and accounts

- **Wallets.** Each recovery phrase or imported private key is a wallet with its own accounts. The
  wallet button on the home screen switches between them and adds new ones. The same secret
  cannot be added twice.
- **Which wallet answers.** A computer asking for a public key gets the **active** wallet's.
  Signing requests name the key that must sign, so they go to the wallet that owns that key,
  whichever is active. A dapp connected earlier to another wallet keeps working, and the approval
  screen says which wallet signs.
- A recovery phrase starts with **Account 1** (`m/44'/397'/0'/0'/1'`, the Ledger default).
  **Add account** derives the next unused number after Face ID. **Custom derivation path** (under
  Advanced) accepts any 5-level hardened path.
- A host may ask for a path that is not in the list yet. The approval screen then says "New on
  this phone", and the account is added once you approve.
- **Remove from list** hides an account and forgets its cached public key, so hosts must ask
  again. The key itself is still derivable from the phrase; adding the same number brings it back.
- An imported private key is a single account and answers every path.
- To use Account N from near-cli-rs, pass `--seed-phrase-hd-path "44'/397'/0'/0'/N'"`.
- **Named accounts.** "NEAR account name" on the account screen sets the named account the key
  controls. Names seen in approved requests are offered as suggestions to confirm with one tap:
  named accounts that signed with the key, and accounts created with it (CreateAccount + AddKey
  on a subaccount of the signer, or `create_account` on the `near` / `testnet` registrar). They
  are never applied automatically, because an app can send a request in any account's name and
  the offline phone cannot check it.

## Readable requests

The core recognizes these operations and gives the app a summary for a dedicated card. The
approval screen shows the warnings first, then the card and anything the request does besides it
(such as a storage deposit paid first, under "Also in this request"); every field, including the
generic per-action ones, is one tap away under "Details", so nothing is hidden. Memos on the card
are cut at four lines, so a long one can't push the rest out of view.

| Operation | Recognized calls | Card |
|---|---|---|
| NEAR transfer | a single `Transfer` action (also in a meta-transaction) | amount with NEAR icon, recipient and its kind, "your account" when it is one of the phone's own |
| Token transfer (NEP-141) | `ft_transfer`, `ft_transfer_call` (with an optional `storage_deposit` first) | amount with token icon, recipient, memo, and the `msg` of a transfer call |
| Wrapped NEAR | `near_deposit`, `near_withdraw` on `wrap.near` / `wrap.testnet` | wrap or unwrap amount |
| NEAR Intents deposit | `ft_transfer_call` to `intents.near` or `intents.far` (also after `near_deposit`) | amount, credited account |
| NEAR Intents on chain | `ft_withdraw`, `mt_transfer`, `add_public_key`, `remove_public_key` on `intents.near` or `intents.far` | withdrawal, transfer, key change |
| NEAR Intents signed message | NEP-413 message with `signer_id`, `deadline`, `intents` (`token_diff`, `transfer`, `ft_withdraw`, `native_withdraw`, key changes; others shown raw) | swap card (you pay / you receive), deadline |
| Sputnik DAO | `add_proposal` (every v2 proposal kind, function-call payloads decoded) and `act_proposal` (votes, finalize) | DAO, what the proposal does (amounts, recipients, calls with their arguments), description, bond, vote; for a vote the proposal comes from the website, so the card marks it unverified (tap the mark for why) |

Transfer cards show the recipient's full account id, implicit ids (64 hex characters, or `0x…`)
included. NEAR sent with a plain transfer, and tokens sent with
`ft_transfer`, get a warning when the recipient is a known token contract or `intents.near` (a
plain transfer doesn't run the contract's code, so nobody is credited), the sender itself, an
account name from the other network, or not a valid account name.

`intents.far` is NEAR Intents on the FAR chain (the contract's `far` build). Its tokens are
internal ones, `imt:<issuer>:<name>`, minted inside NEAR Intents by `issuer`. One named after a
listed token (`imt:…:nep141:wrap.near`) is shown with that token's symbol and decimals. Anyone can
mint a token under any name, so unless the issuer is in `TokenRegistry.trustedIssuers` (FAR's own,
`51e8f94d…7cbe`) the card names it in full and a warning asks to check it.

Warnings are kept for what needs a decision: unusual amounts, recipients that lose funds, keys
that get full access, tokens that can't be taken at face value. How a request works (a relayer
submits a meta-transaction, a DAO calls a contract when a proposal passes) is not a warning, and
the 1 yoctoNEAR confirmation deposit many contracts require reads "1 yoctoNEAR", in normal-size
text. Titles shorten implicit account ids (`5bb0a9…8123ca`); the card shows them in full.

Large requests arrive slowly over Bluetooth (a 1 MB deployment is thousands of APDUs). Once a
request passes 8 KB, a "Receiving a request" card shows the bytes received, speed, time left and
a Cancel button. The total is known early for deployments: the transaction carries the code
length before the code (`TransactionSizeProbe`). Cancel refuses the next chunk with `6985`, which
stops the host, and the cancellation is recorded in the history.

Contract deployments never show the code itself: they show its size, the code hash (base58
sha256, the `code_hash` explorers display, so it can be compared with the expected build) and
whether it is a WebAssembly module. History keeps the raw request but previews only its start.

Token symbols and decimals come only from a built-in list (`Near/Tokens.swift`), because a host
could lie about a token and its metadata cannot be fetched offline. Every entry was checked
against the contract's `ft_metadata` on mainnet. Unknown tokens show their amount in the smallest
units with a warning. `scripts/gen-token-icons.mjs` renders the icons from the same on-chain
metadata into the asset catalog.

The list also has USDC and USDT from other chains as NEAR Intents holds them: NEP-141 tokens of
its own bridge (`eth-0xa0b8…eb48.omft.near` is USDC from Ethereum) and NEP-245 tokens of HOT
Bridge (`nep245:v2_1.omni.hot.tg:…`), listed by their full id. They come from the NEAR Intents
app's token list, were checked against `ft_metadata` or `mt_metadata_base_by_token_id`, and use
the USDC and USDT icons. The card names the chain ("USD Coin (Ethereum)").

## Signing history

Every request that reaches the signer is recorded: approved, rejected (including timeouts and
host disconnects), and failed (undecodable payload, key mismatch, failed authentication). Each
entry contains:

- date, account, derivation path
- signer, receiver, network (inferred from the account names)
- transaction hash (the NEAR tx id), signature, public key
- the raw Borsh payload

The details screen decodes the payload again and shows exactly what was on screen at approval
time. It also shows a QR code of the explorer link, to open on another device. Public-key exports
appear only for the first export of a path and for rejections.

## Testing

### 1. Without a phone (macOS or Linux)

```bash
swift test                    # 93 tests: codecs, near-api-js fixtures, key derivation vectors,
                              # APDU sessions, BLE/TCP framing, wallets, accounts, recognizers
scripts/test-all.sh           # + Python host e2e against the simulator
                              # + near-connect's real Ledger executor over emulated BLE (needs node)
```

`near-signer-sim` runs the iOS app's exact signing core as a desktop device:

```bash
swift run near-signer-sim                       # asks y/N in the terminal for every request
swift run near-signer-sim --auto-approve --history /tmp/h.json
swift run near-signer-sim --seed-phrase "…"     # default: the public BIP-39 test phrase (test only!)
swift run near-signer-sim history --history /tmp/h.json
```

In a second terminal:

```bash
python3 host/python/near_signer_host.py pubkey
python3 host/python/near_signer_host.py sign-tx <base64 unsigned transaction>
python3 host/python/near_signer_host.py sign-message --message hi --recipient app.near
```

### 2. In Xcode with the iOS Simulator

1. Open `iOS/NearSigner.xcodeproj` (Xcode 26 or newer). Xcode resolves the local `NearSignerCore`
   package automatically. The app runs on iOS 17 and later; on iOS 26 and later, its floating
   buttons, bottom bars and alert cards use Liquid Glass.
   If your Xcode refuses the project, run `brew install xcodegen && cd iOS && xcodegen generate`
   instead.
2. Choose an iPhone simulator and press Run (⌘R). No signing team is needed for the Simulator.
3. In the app, choose **Restore with a recovery phrase** and paste the BIP-39 test phrase
   `abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about`.
   Without a Secure Enclave the Simulator stores keys in the plain keychain, so use test keys only.
   (**Create a new wallet** walks through the backup check: three words to pick.)
4. In the Simulator menu choose **Features › Face ID › Enrolled**. When a Face ID prompt appears,
   choose **Features › Face ID › Matching Face**.
5. Try the UI on its own: **Accounts › Simulate a request** (Debug builds only) sends a USDC
   transfer, a NEAR Intents swap, a DAO proposal, a DAO vote or a NEAR transfer.
   **Add account** creates Account 2. **Features › Toggle Appearance** (⇧⌘A) switches the
   Simulator between light and dark; Settings › Appearance overrides it inside the app.
6. Drive it from the Mac. The Simulator has no Bluetooth, so Simulator builds listen on
   `127.0.0.1:9999` (the home screen shows "Simulator mode"):

   ```bash
   python3 host/python/near_signer_host.py pubkey
   # ed25519:EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz for the test phrase
   python3 host/python/near_signer_host.py sign-tx "$(python3 -c 'import json;print(json.load(open("host/python/test_fixtures.json"))["transfer"]["borsh"])')"
   python3 host/python/near_signer_host.py --path "m/44'/397'/0'/0'/3'" pubkey
   # a path the app does not know yet: approve it and Account 3 appears
   ```

   The approval screen opens in the Simulator. Approve it, then confirm Face ID. The signed
   transaction is printed on the Mac, and the entry appears under **History**.
7. Core tests: run `swift test` in the repository root on the Mac. On macOS this uses CryptoKit,
   like the app does. In Xcode, open `Package.swift`, select the `NearSigner-Package` scheme and
   "My Mac", and press ⌘U.

### 3. On a real iPhone

1. In Xcode, open target **NearSigner › Signing & Capabilities**. Pick your team and change the
   bundle id from `com.example.near-signer` to something unique.
2. Turn on Developer Mode on the phone (**Settings › Privacy & Security**), then run the app from
   Xcode. The phone must have a passcode.
3. Create or restore a wallet. Keep the app open: Bluetooth stops in the background.

**Bluetooth with near-cli-rs** (macOS: allow Bluetooth for your terminal app when asked):

```bash
near tokens alice.testnet send-near bob.testnet '0.1 NEAR' network-config testnet \
  sign-with-ledger --seed-phrase-hd-path "44'/397'/0'/0'/1'" bluetooth send
```

What happens:

- The phone shows a pairing request the first time. Accept it.
- Accept the one-time "Share Account 1?" prompt.
- Review the transaction and tap **Approve**.

For Account 2, use `--seed-phrase-hd-path "44'/397'/0'/0'/2'"`.

The phone advertises as a Ledger Nano X. near-cli-rs has no device chooser: it scans for about a
second and connects to the first Ledger-like device in the list, in an order set by the
computer's Bluetooth stack. With several phones running NEAR Signer, or a real Nano X nearby,
keep only one advertising: the app stops Bluetooth in the background, or turn it off in Settings.
Browsers (near-connect) show a chooser instead.

**Bluetooth with a near-connect dapp**:

1. Open the dapp in Chrome or Edge on a computer.
2. Choose the **Ledger** wallet, then **Bluetooth**, then **NEAR Signer** in the browser's device chooser.

**Any other tool** can go through `near-signer-host --ble` (`pip install bleak`), for example
with a transaction prepared offline by near-cli-rs:

```bash
near --offline tokens alice.testnet send-near bob.testnet '0.1 NEAR' network-config testnet \
  sign-later --signer-public-key ed25519:… --nonce <access key nonce + 1> --block-hash <recent block hash> display
python3 host/python/near_signer_host.py --ble sign-tx "<base64 printed by near-cli-rs>"
near transaction send-signed-transaction '<signed base64>' network-config testnet send
```

### 4. Continuous integration and formatting

GitHub Actions runs on every push to `main` or `master` and on every pull request
(`.github/workflows/ci.yml`):

| Job | What it does |
|---|---|
| Format and lint | `scripts/format.sh --check` |
| Fixtures match near-api-js | `scripts/regenerate-fixtures.sh`, then fails if the committed fixtures differ |
| Test (Linux) | `scripts/test-all.sh` in the `swift:6.3-noble` container (swift-crypto) |
| Test (macOS) | `scripts/test-all.sh` on macOS 26 (CryptoKit) |
| Build iOS app | `xcodebuild` for the iOS Simulator (Debug) and for iPhone (Release, unsigned) |

The workflow pins every action to a commit, and Dependabot proposes updates once a release is two
weeks old. Nothing is signed or published: signing needs the developer's own Apple team.

Formatting is checked, so run the formatter before committing:

```bash
brew install swiftformat ruff shellcheck node    # once
scripts/format.sh                                # format in place
scripts/format.sh --check                        # what CI runs: change nothing, fail on differences
```

It runs SwiftFormat on Swift (`.swiftformat`: layout and whitespace only, so the code keeps its own
idioms), Ruff on Python (`ruff.toml`), Prettier on JavaScript (`.prettierrc.json`) and ShellCheck on
the shell scripts. CI uses SwiftFormat 0.63.0, Ruff 0.16.9 and Prettier 3.9.9; other versions can
format a few lines differently. `.editorconfig` gives editors, Xcode included, the same basics.

## Key derivation notes

- Seed phrases use SLIP-10 ed25519, the same as a Ledger. The host chooses the path, and the
  NEAR Ledger protocol always sends 5 hardened levels. The default is `m/44'/397'/0'/0'/1'`.
- near-cli-rs's own seed-phrase default, `m/44'/397'/0'`, has 3 levels and cannot be requested
  over the Ledger protocol. For such an account, do one of the following:
  - Import its `ed25519:…` private key. A single imported key signs for every path.
  - Add the device's key to the account.
- Both derivations are verified against `near-seed-phrase` in the tests.

## What was verified, and what was not

Verified on Linux (Swift 6.2 + swift-crypto):

- **Swift unit tests.** All 100 pass. Encodings match near-api-js byte for byte; delegate and
  NEP-413 digests match; BIP-39, SLIP-10 and near-seed-phrase keys match.
- **Python e2e tests.** All 14 pass, including fast mode over TCP and emulated BLE (checked on the wire). They check signed transactions byte for byte against near-api-js.
- **near-connect.** The real near-connect Ledger executor (fetched from GitHub) completed MTU
  negotiation, get version, get public key, transaction signing and NEP-413 signing over the
  emulated BLE link.
- **near-cli-rs 0.30.1.** Its `sign-later` output was signed through the host CLI and the
  simulator, and `near transaction print-transaction signed` decoded the result with the same hash.

Not verified, because there was no Mac or iPhone:

- Compiling the iOS app target in Xcode. Every app file, SwiftUI included, was type-checked
  against hand-written stand-ins for SwiftUI, UIKit, CoreBluetooth and the other Apple frameworks,
  for both device and Simulator builds. The real SDK may still disagree on details.
- How the screens look, in light and dark mode.
- Bluetooth radio behaviour, including pairing with macOS, Linux and Windows hosts.
