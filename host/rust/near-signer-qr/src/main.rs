//! Signs with NEAR Signer through the phone's camera, from a terminal: the request is shown as a
//! loop of QR codes, the phone answers with one QR code whose text is typed back here. The same
//! commands and options as host/optical/near-signer-qr.mjs, so either drives the repository's
//! end-to-end test.
//!
//!   near-signer-qr pubkey [--path m/44'/397'/0'/0'/1']
//!   near-signer-qr sign-tx --tx BASE64 [--path …] [--public-key ed25519:…]
//!   near-signer-qr sign-message --payload BASE64 [--path …] [--public-key ed25519:…]
//!   near-signer-qr sign-delegate --delegate BASE64 [--path …] [--public-key ed25519:…]
//!   near-signer-qr verify --response TEXT --session-id HEX [--tx|--payload|--delegate BASE64] [--public-key …]
//!   near-signer-qr receive            reads frame texts from standard input, prints the request
//!
//! Display options: --fragment-size N (default: the largest of 220, 160, 120, 80, 50 that fits the
//! terminal), --fps N (default 20), --codes N (codes side by side; default: what fits), --no-compress (send
// the payload as is; by default a payload that shrinks under DEFLATE is sent compressed).
// --tx-file, --payload-file, --delegate-file PATH read the base64 from a file (a deployment is too
// long for an argument)., --invert (dark text on a light terminal), --session-id HEX.
//! Test options (no animation): --frames-out N prints N frame texts, one per line, from
//! --start S (default 0), dropping each with probability --loss P (--seed N) and, with --shuffle,
//! permuting them within windows of 8. Pipe them into `near-signer-sim optical`.

use near_signer_qr::{
    base58, base64, terminal, Kind, Outcome, Receiver, Request, Response, Sender,
};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::process::ExitCode;

const DEFAULT_PATH: &str = "m/44'/397'/0'/0'/1'";

struct Options {
    command: Option<String>,
    values: HashMap<String, String>,
    flags: Vec<String>,
}

impl Options {
    fn parse(args: impl Iterator<Item = String>) -> Result<Self, String> {
        let mut options = Options {
            command: None,
            values: HashMap::new(),
            flags: Vec::new(),
        };
        let mut args = args.peekable();
        while let Some(arg) = args.next() {
            if let Some(name) = arg.strip_prefix("--") {
                if name == "invert" || name == "shuffle" || name == "no-compress" {
                    options.flags.push(name.to_string());
                } else {
                    let value = args.next().ok_or_else(|| format!("{arg} needs a value"))?;
                    options.values.insert(name.to_string(), value);
                }
            } else if options.command.is_none() {
                options.command = Some(arg);
            } else {
                return Err(format!("unexpected argument: {arg}"));
            }
        }
        Ok(options)
    }

    fn value(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    fn flag(&self, name: &str) -> bool {
        self.flags.iter().any(|flag| flag == name)
    }

    fn number<T: std::str::FromStr>(&self, name: &str) -> Result<Option<T>, String> {
        self.value(name)
            .map(|value| {
                value
                    .parse::<T>()
                    .map_err(|_| format!("--{name} needs a number, not {value}"))
            })
            .transpose()
    }
}

fn usage(message: &str) -> ExitCode {
    if !message.is_empty() {
        eprintln!("{message}");
    }
    eprintln!("usage: near-signer-qr pubkey|sign-tx|sign-message|sign-delegate|verify|receive [options]; see the source header");
    ExitCode::from(2)
}

/// What to send, and how to check the answer.
struct Job {
    request: Request,
    /// The key the answer is checked against: given, or read from the transaction or delegate action.
    public_key: Option<[u8; 32]>,
}

fn public_key_bytes(text: &str) -> Result<[u8; 32], String> {
    let encoded = text.strip_prefix("ed25519:").unwrap_or(text);
    base58::decode(encoded)
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .ok_or_else(|| format!("not an ed25519 public key: {text}"))
}

/// `--NAME BASE64`, or `--NAME-file PATH` for a file holding the base64 (a contract deployment is
/// too long for a command-line argument).
fn base64_option(options: &Options, name: &str) -> Result<Vec<u8>, String> {
    let file_option = format!("{name}-file");
    let text = match (options.value(name), options.value(&file_option)) {
        (Some(text), _) => text.to_string(),
        (None, Some(path)) => std::fs::read_to_string(path)
            .map_err(|error| format!("--{file_option} {path}: {error}"))?,
        (None, None) => return Err(format!("--{name} BASE64 or --{file_option} PATH is needed")),
    };
    base64::decode(text.trim()).ok_or_else(|| format!("--{name} is not base64"))
}

/// The ed25519 key a borsh Transaction names (after the signer id), or None for another key type.
fn transaction_public_key(tx: &[u8]) -> Option<[u8; 32]> {
    let id_len = u32::from_le_bytes(tx.get(0..4)?.try_into().ok()?) as usize;
    let offset = 4 + id_len;
    (*tx.get(offset)? == 0)
        .then(|| tx.get(offset + 1..offset + 33)?.try_into().ok())
        .flatten()
}

/// The ed25519 key a borsh DelegateAction names (its last field), or None for another key type.
fn delegate_public_key(delegate: &[u8]) -> Option<[u8; 32]> {
    let len = delegate.len();
    (len >= 33 && delegate[len - 33] == 0)
        .then(|| delegate[len - 32..].try_into().ok())
        .flatten()
}

fn build_job(command: &str, options: &Options) -> Result<Job, String> {
    let path = options.value("path").unwrap_or(DEFAULT_PATH);
    let given = options
        .value("public-key")
        .map(public_key_bytes)
        .transpose()?;
    let (kind, payload, derived) = match command {
        "pubkey" => (Kind::PublicKey, Vec::new(), None),
        "sign-tx" => {
            let tx = base64_option(options, "tx")?;
            let key = transaction_public_key(&tx);
            (Kind::Transaction, tx, key)
        }
        "sign-message" => (Kind::Nep413, base64_option(options, "payload")?, None),
        "sign-delegate" => {
            let delegate = base64_option(options, "delegate")?;
            let key = delegate_public_key(&delegate);
            (Kind::Nep366, delegate, key)
        }
        other => return Err(format!("unknown command: {other}")),
    };
    let request = Request::new(kind, path, payload).map_err(|error| error.to_string())?;
    Ok(Job {
        request,
        public_key: given.or(derived),
    })
}

fn json_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn print_json(fields: &[(&str, String)]) {
    println!("{{");
    for (index, (name, value)) in fields.iter().enumerate() {
        println!(
            "  {}: {}{}",
            json_string(name),
            value,
            if index + 1 < fields.len() { "," } else { "" }
        );
    }
    println!("}}");
}

/// Checks a response against the job and prints the result as JSON. The exit code says whether
/// the answer is usable.
fn report(response: &Response, job: &Job, session_id: u32) -> Result<ExitCode, String> {
    if response.session_id != session_id {
        return Err(format!(
            "the response is for another request (session {:08x}, this one is {session_id:08x})",
            response.session_id
        ));
    }
    let mut fields = vec![
        ("status", json_string(&format!("{:04X}", response.status))),
        ("statusMessage", json_string(response.status_message())),
        ("sessionId", json_string(&format!("{session_id:08x}"))),
    ];
    if response.status != 0x9000 {
        fields.push(("error", json_string(response.status_message())));
        print_json(&fields);
        return Ok(ExitCode::from(1));
    }
    if job.request.kind == Kind::PublicKey {
        let key = response
            .public_key()
            .ok_or("the response does not hold a 32-byte public key")?;
        fields.push((
            "publicKey",
            json_string(&format!("ed25519:{}", base58::encode(&key))),
        ));
        fields.push(("implicitAccountId", json_string(&hex(&key))));
        print_json(&fields);
        return Ok(ExitCode::SUCCESS);
    }
    let signature = response
        .signature()
        .ok_or("the response does not hold a 64-byte signature")?;
    fields.push(("signature", json_string(&base64::encode(&signature))));
    if job.request.kind == Kind::Transaction {
        // borsh(SignedTransaction): the transaction, then the signature as key type 0 (ed25519).
        let mut signed = job.request.payload.clone();
        signed.push(0);
        signed.extend_from_slice(&signature);
        fields.push(("signedTransaction", json_string(&base64::encode(&signed))));
    }
    let sent = job.request.message_for_transfer().len();
    fields.push(("payloadBytes", job.request.payload.len().to_string()));
    if sent < job.request.message().len() {
        fields.push(("sentBytesCompressed", sent.to_string()));
    }
    let verified = match (job.public_key, job.request.digest()) {
        (Some(key), Some(digest)) => {
            fields.push((
                "publicKey",
                json_string(&format!("ed25519:{}", base58::encode(&key))),
            ));
            if !near_signer_qr::verify(&key, &digest, &signature) {
                return Err("the signature does not verify against the key".to_string());
            }
            true
        }
        _ => false,
    };
    fields.push(("verified", verified.to_string()));
    print_json(&fields);
    Ok(ExitCode::SUCCESS)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// mulberry32, seeded like the JavaScript CLI, so `--seed` gives comparable losses.
fn mulberry32(seed: u32) -> impl FnMut() -> f64 {
    let mut state = seed;
    move || {
        state = state.wrapping_add(0x6D2B_79F5);
        let mut t = state;
        t = (t ^ (t >> 15)).wrapping_mul(t | 1);
        t ^= t.wrapping_add((t ^ (t >> 7)).wrapping_mul(t | 61));
        f64::from(t ^ (t >> 14)) / 4_294_967_296.0
    }
}

/// Frame texts with the losses and reordering of a real camera, for tests.
fn frames_out(sender: &Sender, count: u32, options: &Options) -> Result<(), String> {
    let start: u32 = options.number("start")?.unwrap_or(0);
    let loss: f64 = options.number("loss")?.unwrap_or(0.0);
    let mut random = mulberry32(options.number("seed")?.unwrap_or(1));
    let mut frames: Vec<String> = (start..start.saturating_add(count))
        .filter(|_| random() >= loss)
        .map(|s| sender.frame(s))
        .collect();
    if options.flag("shuffle") {
        for window in frames.chunks_mut(8) {
            for i in (1..window.len()).rev() {
                let j = (random() * (i + 1) as f64) as usize;
                window.swap(i, j);
            }
        }
    }
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    for frame in frames {
        match writeln!(out, "{frame}") {
            Ok(()) => {}
            // The reader (near-signer-sim) has what it needs and closed the pipe.
            Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => return Ok(()),
            Err(error) => return Err(error.to_string()),
        }
    }
    Ok(())
}

/// Reads frame texts from standard input and prints the request they carry.
fn receive() -> Result<ExitCode, String> {
    let mut receiver = Receiver::new();
    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let line = line.map_err(|error| error.to_string())?;
        match receiver.receive(line.trim()) {
            Outcome::Complete(message) => {
                let request =
                    Request::parse(&message).ok_or("the message is not a NEAR Signer request")?;
                print_json(&[
                    ("kind", json_string(request.kind.name())),
                    ("path", json_string(&request.path_string())),
                    ("payload", json_string(&base64::encode(&request.payload))),
                    (
                        "sessionId",
                        json_string(&format!("{:08x}", receiver.session_id().unwrap_or(0))),
                    ),
                ]);
                return Ok(ExitCode::SUCCESS);
            }
            Outcome::Invalid(reason) => eprintln!("{reason}"),
            _ => {}
        }
    }
    Err("the input ended before the request was complete".to_string())
}

fn run() -> Result<ExitCode, String> {
    let options = Options::parse(std::env::args().skip(1))?;
    let Some(command) = options.command.as_deref() else {
        return Ok(usage(""));
    };
    if command == "--help" || command == "help" {
        return Ok(usage(""));
    }
    if command == "receive" {
        return receive();
    }
    let session_id = options
        .value("session-id")
        .map(|text| {
            u32::from_str_radix(text, 16).map_err(|_| format!("--session-id needs hex, not {text}"))
        })
        .transpose()?;
    if command == "verify" {
        let response_text = options
            .value("response")
            .ok_or("verify needs --response TEXT")?;
        let session_id = session_id.ok_or("verify needs --session-id HEX")?;
        let has = |name: &str| {
            options.value(name).is_some() || options.value(&format!("{name}-file")).is_some()
        };
        let base = if has("tx") {
            "sign-tx"
        } else if has("payload") {
            "sign-message"
        } else if has("delegate") {
            "sign-delegate"
        } else {
            "pubkey"
        };
        let job = build_job(base, &options)?;
        let response = Response::parse(response_text)
            .ok_or("not a NEAR Signer response code (check for typos)")?;
        return report(&response, &job, session_id);
    }
    let job = build_job(command, &options)?;
    let fragment_size: Option<usize> = options.number("fragment-size")?;
    if let Some(count) = options.number::<u32>("frames-out")? {
        let session_id = session_id.unwrap_or_else(terminal::random_session_id);
        let message = if options.flag("no-compress") {
            job.request.message()
        } else {
            job.request.message_for_transfer()
        };
        let sender = Sender::new(message, session_id, fragment_size.unwrap_or(220))
            .map_err(|error| error.to_string())?;
        frames_out(&sender, count, &options)?;
        return Ok(ExitCode::SUCCESS);
    }
    let terminal_options = terminal::Options {
        caption: None,
        fragment_size,
        fps: options.number("fps")?.unwrap_or(20),
        codes_per_frame: options.number("codes")?,
        invert: options.flag("invert"),
        session_id,
        compress: !options.flag("no-compress"),
    };
    let session_id = terminal_options
        .session_id
        .unwrap_or_else(terminal::random_session_id);
    let terminal_options = terminal::Options {
        caption: None,
        session_id: Some(session_id),
        ..terminal_options
    };
    let response =
        terminal::run(&job.request, &terminal_options).map_err(|error| error.to_string())?;
    report(&response, &job, session_id)
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(1)
        }
    }
}
