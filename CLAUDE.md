# NEAR Signer

An iPhone app that acts as a NEAR hardware wallet: it emulates a Ledger Nano X running the NEAR app
over Bluetooth, so near-connect, near-cli-rs and Ledger Live use it unchanged. README.md documents
the protocol, the security model and every recognized request; read the relevant section before
changing behavior.

## Layout

- `Sources/NearSignerCore/`: all protocol, decoding, display and signing logic. Platform
  independent (iOS, macOS, Linux): no UIKit, SwiftUI or CoreBluetooth. Crypto comes from
  `Crypto/CryptoImport.swift` (CryptoKit on Apple platforms, swift-crypto on Linux).
- `Sources/near-signer-sim/`: the core as a desktop "device" over TCP, used by the host tests.
- `iOS/NearSigner/`: the app (SwiftUI, Secure Enclave key vault, CoreBluetooth peripheral).
- `host/python/`: `near-signer-host` CLI and end-to-end tests. Standard library only (`bleak` for
  Bluetooth).
- `host/compat/`: runs near-connect's real Ledger executor against the simulator.
- `host/optical/`: the computer side of the camera transfer (QR codes): dependency-free codec,
  terminal CLI, browser page, and the near-connect executor and its camera page built from them
  (the browser side vendors a QR generator and the jsQR reader). The wire format is in README
  "Camera transfer".
- `host/rust/near-signer-qr/`: the same in Rust (a crate for near-cli-rs, plus a binary with the
  JavaScript CLI's commands). The three implementations must stay byte for byte compatible;
  `cargo test` holds shared vectors and CI pipes the JavaScript frames into the Rust receiver.

## Commands

- `scripts/test-all.sh`: every test that needs no phone (Swift, Python e2e, near-connect, the
  camera transfer through `near-signer-sim optical` from the JavaScript and, when cargo is
  installed, the Rust sender). Needs Swift, python3 and Node.js; Rust is optional.
- `scripts/format.sh` formats; `scripts/format.sh --check` is the CI gate (SwiftFormat 0.63.0,
  Ruff 0.16.9, Prettier 3.9.9, ESLint from `host/optical/package.json`, ShellCheck).
- In `host/optical`: `npm run lint`, `npm test` (the codec's unit tests), `npm run build`
  (rebuilds the committed `near-signer-qr-executor.js`; CI fails if it differs).
- `scripts/regenerate-fixtures.sh`: rebuilds `Tests/NearSignerCoreTests/Fixtures.swift` and
  `host/python/test_fixtures.json` from near-api-js. Never edit those files by hand; CI checks
  they match.
- The iOS app builds only on macOS with Xcode 26 (`xcodebuild -project iOS/NearSigner.xcodeproj
  -scheme NearSigner`). On Linux, only the core and the host tools can be built and tested.

## Rules

- Whatever the host sends is untrusted. Every string shown passes through `NearFormat.visible`
  (`RequestDisplay.sanitized()`, `Highlight.sanitized()`); a new displayed field must too.
- Recognizers build a summary card only when every value parses exactly as the contract reads it;
  otherwise they return nil and the raw request is shown. Never guess, never hide a field.
- The phone signs only bytes it decoded, displayed, and re-encoded to the identical bytes. Unknown
  actions are refused, never blind-signed.
- The Bluetooth and APDU behavior must stay compatible with near-connect, near-ledger-rs and Ledger
  Live (see README "Protocol"); check them before changing framing or status words.
- A security fix gets a regression test in `Tests/NearSignerCoreTests/AuditRegressionTests.swift`.
- `iOS/NearSigner/` is a synchronized folder: new files are picked up without editing
  `project.pbxproj`. A build setting changed there must also change in `iOS/project.yml`
  (XcodeGen fallback).
- README.md describes the current behavior only: update the section a change affects, in the
  present tense, and the test counts it states. No changelogs or audit write-ups.
