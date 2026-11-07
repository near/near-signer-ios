# near-signer-qr

The computer's side of NEAR Signer's camera transfer. [NEAR Signer](https://github.com/near/near-signer-ios)
is an iPhone app that keeps NEAR keys like a hardware wallet. Without Bluetooth, a request travels to
the phone as a loop of QR codes on the computer's screen, and the phone answers with one QR code
whose text is typed back.

The crate encodes the requests, parses and checks the answers, and runs the whole exchange in a
terminal. near-cli-rs uses it for `sign-with-near-signer-qr`. The request codes are `NS1:` frames of
base45 text carrying a fountain code, so the phone can start reading at any code and miss some. The
wire format is in the NEAR Signer README, "Camera transfer (QR codes)"; the app (Swift) and the
browser tools (JavaScript) implement the same bytes.

## Library

```rust
use near_signer_qr::{terminal, verify, Kind, Request};

/// Asks the phone to sign `transaction` (borsh-serialized) with the key at the default path.
fn sign(transaction: Vec<u8>, public_key: &[u8; 32]) -> Result<[u8; 64], Box<dyn std::error::Error>> {
    let request = Request::new(Kind::Transaction, "m/44'/397'/0'/0'/1'", transaction)?;
    // Draws the codes until the phone's answer is typed under them.
    let response = terminal::run(&request, &terminal::Options::default())?;
    let signature = response.signature().ok_or(response.status_message())?;
    let digest = request.digest().ok_or("a signing request has a digest")?;
    if !verify(public_key, &digest, &signature) {
        return Err("the signature doesn't verify against the public key".into());
    }
    Ok(signature)
}
```

`Kind` selects what the phone does, with the payload the Ledger NEAR app takes for the same
instruction: `PublicKey` (no payload), `Transaction` (`borsh(Transaction)`), `Nep413`
(`borsh(Payload)` of a NEP-413 message) and `Nep366` (`borsh(DelegateAction)`). The path is exactly
five hardened levels under `44'/397'`.

The pieces are public for tools that draw the codes themselves: `Request::message_for_transfer` and
`Sender` make the frame texts, `Response::parse` reads the answer, `terminal::Session` animates the
codes under a prompt of your own, and `Receiver` is the phone's side.

## Command line

```bash
cargo install near-signer-qr
near-signer-qr pubkey [--path "m/44'/397'/0'/0'/1'"]
near-signer-qr sign-tx --tx BASE64 [--path …] [--public-key ed25519:…]
near-signer-qr sign-message --payload BASE64 [--path …] [--public-key ed25519:…]
near-signer-qr sign-delegate --delegate BASE64 [--path …] [--public-key ed25519:…]
```

Each command shows the request as QR codes and asks for the code under the phone's answer. The
commands and options match the repository's JavaScript `near-signer-qr.mjs`.

## License

MIT
