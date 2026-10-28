#!/usr/bin/env node
// Signs with NEAR Signer through the phone's camera, from a terminal: the request is shown as a
// loop of QR codes, the phone answers with one QR code whose text is typed back here. See
// README.md "Camera transfer". No npm dependencies.
//
//   near-signer-qr.mjs pubkey [--path m/44'/397'/0'/0'/1']
//   near-signer-qr.mjs sign-tx --tx BASE64 | --tx-file FILE [--path …] [--public-key ed25519:…]
//                       (--payload-file and --delegate-file likewise: a deployment is too long for an argument)
//   near-signer-qr.mjs sign-message --payload BASE64 [--path …] [--public-key ed25519:…]
//   near-signer-qr.mjs sign-delegate --delegate BASE64 [--path …] [--public-key ed25519:…]
//   near-signer-qr.mjs verify --response TEXT --session-id HEX [--tx|--payload|--delegate BASE64] [--public-key …]
//   near-signer-qr.mjs receive           reads frame texts from stdin and prints the decoded request
//
// Payloads of 64 bytes or more are sent compressed (raw DEFLATE) when that makes them smaller;
// --no-compress sends them as they are.
// Display options: --fragment-size N (default: the largest that fits the terminal, up to 1200),
// --fps N (default 20), --codes N (codes side by side; default: what fits), --invert (dark text on a light terminal), --session-id HEX.
// Test options (no animation): --frames-out N prints N frame texts, one per line, from
// --start S (default 0), dropping each with probability --loss P (--seed N) and, with --shuffle,
// permuting them within windows of 8. Pipe them into `near-signer-sim optical`.

import crypto from "node:crypto";
import readline from "node:readline";
import fs from "node:fs";
import zlib from "node:zlib";
import {
    encodeRequest,
    grouped,
    inflateRequest,
    INSTRUCTIONS,
    parseRequest,
    parseResponse,
    randomSessionId,
    Receiver,
    Sender,
    statusMessage,
} from "./optical.mjs";
import {
    NEP366_PREFIX,
    NEP413_PREFIX,
    base58Decode,
    base58Encode,
    concat,
    delegatePublicKey,
    transactionPublicKey,
} from "./borsh.mjs";
import { qrMatrix, renderTerminal } from "./qr.mjs";

const DEFAULT_PATH = "m/44'/397'/0'/0'/1'";

function usage(message) {
    if (message) console.error(message);
    console.error(
        "usage: near-signer-qr.mjs pubkey|sign-tx|sign-message|sign-delegate|verify [options]; see the file header",
    );
    process.exit(2);
}

function parseArgs(argv) {
    const options = { _: [] };
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (!arg.startsWith("--")) {
            options._.push(arg);
        } else if (["--invert", "--shuffle", "--no-compress"].includes(arg)) {
            options[arg.slice(2)] = true;
        } else {
            if (i + 1 >= argv.length) usage(`${arg} needs a value`);
            options[arg.slice(2)] = argv[++i];
        }
    }
    return options;
}

// MARK: - Encodings

function base64Decode(text) {
    return new Uint8Array(Buffer.from(text.trim(), "base64"));
}

const sha256 = (bytes) => new Uint8Array(crypto.createHash("sha256").update(bytes).digest());

function verifyEd25519(publicKey, message, signature) {
    const spki = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(publicKey)]);
    const key = crypto.createPublicKey({ key: spki, format: "der", type: "spki" });
    return crypto.verify(null, Buffer.from(message), key, Buffer.from(signature));
}

function publicKeyBytes(text) {
    return base58Decode(text.startsWith("ed25519:") ? text.slice(8) : text);
}

// MARK: - The request

/// Raw DEFLATE of a payload worth compressing (64 bytes or more, and smaller once compressed):
/// contract code shrinks about three times, a transfer not at all.
function deflateIfSmaller(payload) {
    if (payload.length < 64) return undefined;
    const deflated = new Uint8Array(zlib.deflateRawSync(payload, { level: 9 }));
    // Four bytes of the message hold the inflated length.
    return deflated.length + 4 < payload.length ? deflated : undefined;
}

/// The payload of a request read from frames, inflated when it was sent compressed.
function inflateBounded(deflated, expectedLength) {
    return new Uint8Array(zlib.inflateRawSync(deflated, { maxOutputLength: expectedLength }));
}

/// `receive`: the phone's side without a camera, for tests. Frame texts come in on stdin.
async function receive() {
    const receiver = new Receiver();
    const input = readline.createInterface({ input: process.stdin, terminal: false });
    for await (const line of input) {
        const text = line.trim();
        if (!text) continue;
        const outcome = receiver.receive(text);
        if (outcome.kind !== "complete") continue;
        const parsed = parseRequest(outcome.message);
        if (!parsed) {
            console.error("the message is not a NEAR Signer request");
            return 1;
        }
        const request = inflateRequest(parsed, inflateBounded);
        console.log(
            JSON.stringify(
                {
                    kind: request.kind,
                    path: request.path,
                    payload: Buffer.from(request.payload).toString("base64"),
                    bytes: request.payload.length,
                    ...(parsed.compressed ? { sentAs: outcome.message.length } : {}),
                },
                null,
                2,
            ),
        );
        return 0;
    }
    console.error("the frames ended before the request was complete");
    return 1;
}

/// `--tx BASE64` or `--tx-file FILE` (and the same for payload and delegate): a contract
/// deployment is too long for a command-line argument.
function base64Option(options, name) {
    if (options[name]) return options[name];
    if (options[`${name}-file`]) return fs.readFileSync(options[`${name}-file`], "utf8").trim();
    return undefined;
}

/// What to send and how to check the answer, from the command line.
function buildRequest(command, options) {
    const path = options.path ?? DEFAULT_PATH;
    const given = options["public-key"] ? publicKeyBytes(options["public-key"]) : null;
    switch (command) {
        case "pubkey":
            return { kind: "publicKey", path, payload: new Uint8Array(0), digest: null, publicKey: null };
        case "sign-tx": {
            if (!options.tx) usage("sign-tx needs --tx BASE64");
            const tx = base64Decode(options.tx);
            return {
                kind: "transaction",
                path,
                payload: tx,
                digest: sha256(tx),
                publicKey: given ?? transactionPublicKey(tx),
            };
        }
        case "sign-message": {
            if (!options.payload) usage("sign-message needs --payload BASE64 (a borsh NEP-413 payload)");
            const payload = base64Decode(options.payload);
            return { kind: "nep413", path, payload, digest: sha256(concat(NEP413_PREFIX, payload)), publicKey: given };
        }
        case "sign-delegate": {
            if (!options.delegate) usage("sign-delegate needs --delegate BASE64 (a borsh DelegateAction)");
            const delegate = base64Decode(options.delegate);
            return {
                kind: "nep366",
                path,
                payload: delegate,
                digest: sha256(concat(NEP366_PREFIX, delegate)),
                publicKey: given ?? delegatePublicKey(delegate),
            };
        }
        default:
            return usage(`unknown command: ${command}`);
    }
}

/// Checks a response against the request; the result is printed as JSON. Throws when it is wrong.
function checkResponse(text, request, sessionId) {
    const response = parseResponse(text);
    if (!response) throw new Error("not a NEAR Signer response code (check for typos)");
    if (response.sessionId !== sessionId) throw new Error("the response is for another request");
    const result = {
        status: response.status.toString(16).padStart(4, "0").toUpperCase(),
        statusMessage: statusMessage(response.status),
        sessionId: sessionId.toString(16).padStart(8, "0"),
    };
    if (response.status !== 0x9000) {
        result.error = result.statusMessage;
        return result;
    }
    if (request.kind === "publicKey") {
        if (response.result.length !== 32) throw new Error("the response does not hold a 32-byte public key");
        result.publicKey = `ed25519:${base58Encode(response.result)}`;
        result.implicitAccountId = Buffer.from(response.result).toString("hex");
        return result;
    }
    if (response.result.length !== 64) throw new Error("the response does not hold a 64-byte signature");
    result.signature = Buffer.from(response.result).toString("base64");
    if (request.kind === "transaction") {
        // borsh(SignedTransaction): the transaction, then the signature as key type 0 (ed25519).
        result.signedTransaction = Buffer.from(concat(request.payload, Uint8Array.of(0), response.result)).toString(
            "base64",
        );
    }
    if (request.publicKey) {
        result.publicKey = `ed25519:${base58Encode(request.publicKey)}`;
        if (!verifyEd25519(request.publicKey, request.digest, response.result)) {
            throw new Error("the signature does not verify against the key");
        }
        result.verified = true;
    } else {
        result.verified = false;
    }
    return result;
}

// MARK: - Frames

function mulberry32(seed) {
    let state = seed >>> 0;
    return () => {
        state = (state + 0x6d2b79f5) >>> 0;
        let t = state;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 2 ** 32;
    };
}

/// Frame texts with the losses and reordering of a real camera, for tests.
function framesOut(sender, options) {
    const count = Number(options["frames-out"]);
    const start = Number(options.start ?? 0);
    const loss = Number(options.loss ?? 0);
    const random = mulberry32(Number(options.seed ?? 1));
    let frames = [];
    for (let s = start; s < start + count; s++) {
        if (random() >= loss) frames.push(sender.frame(s));
    }
    if (options.shuffle) {
        for (let w = 0; w < frames.length; w += 8) {
            const window = frames.slice(w, w + 8);
            for (let i = window.length - 1; i > 0; i--) {
                const j = Math.floor(random() * (i + 1));
                [window[i], window[j]] = [window[j], window[i]];
            }
            frames.splice(w, window.length, ...window);
        }
    }
    process.stdout.write(frames.map((frame) => frame + "\n").join(""));
}

/// The largest fragment size whose code fits the terminal, so the whole code is on screen.
function fittingFragmentSize(rows) {
    // The biggest code that leaves 6 lines under it (status, instructions, hint, blank, prompt).
    // Terminal height is what limits the speed. Letters in the sample: digits would pack tighter.
    for (const size of [1200, 1000, 800, 650, 500, 400, 300, 220, 160, 120, 80, 50]) {
        const lines = renderTerminal(qrMatrix("NS1:" + "A".repeat(Math.ceil((19 + size) * 1.5)))).length;
        if (lines + 6 <= rows) return size;
    }
    return 50;
}

/// How many codes fit side by side, up to three: the phone reads them all from one camera frame.
function codesSideBySide(columns, codeWidth) {
    return Math.max(1, Math.min(3, Math.floor((columns + 2) / (codeWidth + 2))));
}

/// Several codes side by side, two spaces apart.
function renderRow(texts, options) {
    const codes = texts.map((text) => renderTerminal(qrMatrix(text), options));
    const height = Math.max(...codes.map((lines) => lines.length));
    return Array.from({ length: height }, (_, row) => codes.map((lines) => lines[row] ?? "").join("  "));
}

/// Shows the frames until a response is typed, then checks it.
async function animate(request, sender, options) {
    const fps = Number(options.fps ?? 20);
    const invert = Boolean(options.invert);
    const out = process.stdout;
    let sequence = 0;
    const instructions =
        'Phone: open NEAR Signer, tap "Scan from computer", point it here. Type or paste its answer below.';
    const first = renderTerminal(qrMatrix(sender.frame(0)), { invert });
    // Never more codes than there are pieces: a request that fits one code is one code, and it
    // stands still (every frame would carry the same piece).
    const perFrame = Math.min(
        options.codes
            ? Math.max(1, Math.min(3, Number(options.codes)))
            : codesSideBySide(process.stdout.columns ?? 100, first[0]?.length ?? 0),
        sender.fragmentCount,
    );
    // Every piece on screen at once stands still; more pieces than fit go round in a loop.
    const count = sender.fragmentCount;
    const animated = count > perFrame;
    const shown = !animated ? "" : perFrame === 1 ? ", one at a time in a loop" : `, ${perFrame} at a time in a loop`;
    const status = count > 1 ? [`${count} codes${shown}; keep the phone on them until it has all ${count}.`] : [];
    if (request.sizeNote) status.push(request.sizeNote);
    // Small codes mean a slow transfer; say what helps while it is on screen.
    const hint =
        animated && sender.fragmentSize < 500
            ? ["Next time, a taller window or a smaller font (⌘-) gives bigger codes and a faster transfer."]
            : [];
    // One write per frame, inside synchronized output (DEC mode 2026) so a terminal paints the
    // whole frame at once instead of flickering through its tens of kilobytes; terminals without
    // the mode ignore it. Cursor saved and restored, so the prompt under the codes keeps its place.
    const draw = () => {
        const texts = Array.from({ length: perFrame }, (_, offset) => sender.frame(sequence + offset));
        const lines = renderRow(texts, { invert });
        lines.push(...status, instructions, ...hint);
        out.write(`\x1b[?2026h\x1b[s\x1b[H${lines.join("\x1b[K\r\n")}\x1b[K\r\n\x1b[u\x1b[?2026l`);
        sequence += perFrame;
    };
    out.write("\x1b[2J\x1b[H");
    const height = first.length;
    out.write("\r\n".repeat(height + 2 + status.length + hint.length));
    out.write("Code from the phone: ");
    draw();
    const timer = animated ? setInterval(draw, Math.max(20, Math.round(1000 / fps))) : null;
    const input = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
    try {
        for await (const line of input) {
            const text = line.trim();
            if (!text) {
                out.write("Code from the phone: ");
                continue;
            }
            try {
                const result = checkResponse(text, request, sender.sessionId);
                clearInterval(timer);
                out.write("\x1b[2J\x1b[H");
                console.log(JSON.stringify(result, null, 2));
                return result.error ? 1 : 0;
            } catch (error) {
                out.write(`${error.message}. Try again.\nCode from the phone: `);
            }
        }
        return 1;
    } finally {
        clearInterval(timer);
        input.close();
    }
}

async function main() {
    const options = parseArgs(process.argv.slice(2));
    for (const name of ["tx", "payload", "delegate"]) options[name] = base64Option(options, name);
    const command = options._[0];
    if (!command || command === "--help") usage();
    const sessionId = options["session-id"] ? parseInt(options["session-id"], 16) >>> 0 : randomSessionId();
    if (command === "verify") {
        if (!options.response) usage("verify needs --response TEXT");
        const base = options.tx
            ? "sign-tx"
            : options.payload
              ? "sign-message"
              : options.delegate
                ? "sign-delegate"
                : "pubkey";
        const request = buildRequest(base, options);
        try {
            const result = checkResponse(options.response, request, sessionId);
            console.log(JSON.stringify(result, null, 2));
            return result.error ? 1 : 0;
        } catch (error) {
            console.error(error.message);
            return 1;
        }
    }
    if (command === "receive") return receive();
    const request = buildRequest(command, options);
    const deflated = options["no-compress"] ? undefined : deflateIfSmaller(request.payload);
    const message = encodeRequest({ ...request, deflated });
    // What the status line says about the size: the payload, and what is sent when compressed.
    request.sizeNote =
        message.length < 21 + request.payload.length
            ? `${request.payload.length} bytes, sent as ${message.length} compressed`
            : null;
    const fragmentSize = options["fragment-size"]
        ? Number(options["fragment-size"])
        : process.stdout.isTTY
          ? fittingFragmentSize(process.stdout.rows ?? 40)
          : 220;
    const sender = new Sender(message, { sessionId, fragmentSize });
    if (options["frames-out"]) {
        if (request.sizeNote) console.error(request.sizeNote);
        framesOut(sender, options);
        return 0;
    }
    if (!process.stdout.isTTY) usage("not a terminal; use --frames-out to print frames");
    return animate(request, sender, options);
}

// A reader that has what it needs (near-signer-sim after the last piece) closes the pipe while
// frames are still being written; that is the normal end of --frames-out, not an error.
process.stdout.on("error", (error) => {
    if (error.code === "EPIPE") process.exit(0);
    throw error;
});

// No process.exit: it would cut off frames still queued for a pipe (a deployment is megabytes).
main().then(
    (code) => {
        process.exitCode = code;
    },
    (error) => {
        console.error(error.message ?? error);
        process.exitCode = 1;
    },
);

// Exported for the tests and for other tools that want the same checks.
export { INSTRUCTIONS, buildRequest, checkResponse, grouped };
