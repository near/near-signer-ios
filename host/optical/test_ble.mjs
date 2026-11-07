// Tests of the executor's Bluetooth transport (executor/ble.js) in Node: the pure parts first
// (Ledger framing, APDU layout, chunking, the status words), then the whole thing against
// near-signer-sim --ble-packets through the fake navigator.bluetooth of host/compat/, which
// forwards GATT writes to the simulator over TCP and turns its replies into notifications. The
// simulator is started here, on a port of its own, so this needs it built:
//
//   swift build --product near-signer-sim && node host/optical/test_ble.mjs
//
// (NEAR_SIGNER_SIM names another binary, NEAR_SIGNER_SIM_PORT another port.) ble.js is a plain
// script for the executor's bundle, so it runs here in a vm context with the two functions it
// takes from optical.mjs, as host/compat/near-connect-ledger-executor.mjs runs near-connect's.
//
// The quantum-safe key is asked for at the same path as the classic one, 44'/397'/0'/0'/1',
// with P1's bit 0x40 on every command: the simulator answers with the phrase's ML-DSA-65 key
// (the one `near-signer-sim pubkey --key-type ml-dsa-65` prints) and signs with it. Node has no
// ML-DSA-65, so its signatures are checked by their size and by the phone's refusals across
// the two trees.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import vm from "node:vm";
import { after, before, test } from "node:test";
import { pathBytes, statusMessage } from "./optical.mjs";
import { NEP413_PREFIX, base58Decode, buildTransaction, concat, nep413Payload, publicKeyString } from "./borsh.mjs";
import { makeFakeBluetooth } from "../compat/fake-bluetooth.mjs";

const SIM = process.env.NEAR_SIGNER_SIM ?? new URL("../../.build/debug/near-signer-sim", import.meta.url).pathname;
const PORT = Number(process.env.NEAR_SIGNER_SIM_PORT ?? 9996);
const CLASSIC_PATH = "44'/397'/0'/0'/1'";
// The BIP-39 test phrase's key at the classic path, and a transfer it signs (Fixtures.swift).
const CLASSIC_KEY = "ed25519:EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz";
const TRANSFER_TX =
    "DQAAAGFsaWNlLnRlc3RuZXQAxXHjPi42wsco1hfqd6iOIyDIaX6si0Y638ASi5aCXL8HAAAAAAAAAAsAAABib2IudGVzdG5ldDlKvrNecHYJ3o9ztj1DvRo3b/5nk1yqaJN90pvATmc8AQAAAAMAAIBxZDO2KaM9AQAAAAAA";

/// ble.js's functions, run with `navigator` in scope.
function loadBle(navigator) {
    const source = fs.readFileSync(new URL("./executor/ble.js", import.meta.url), "utf8");
    const context = vm.createContext({
        navigator,
        pathBytes,
        statusMessage,
        setTimeout,
        clearTimeout,
        console,
        Uint8Array,
        DataView,
        Error,
    });
    vm.runInContext(
        `${source}\n;globalThis.__ble = { bleAvailable, bleConnect, bleRequest, bleGetVersion, bleGetPublicKey, bleSign,` +
            " blePackets, BleReassembler, BleStatusError };",
        context,
    );
    return context.__ble;
}

const sha256 = async (bytes) => new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));

/// As the executor checks an ed25519 signature: WebCrypto's Ed25519 over the digest.
async function verifyEd25519(publicKey, digest, signature) {
    const key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
    return crypto.subtle.verify("Ed25519", key, signature, digest);
}

const hex = (bytes) => Buffer.from(bytes).toString("hex");

// MARK: - The pure parts

test("Ledger framing: packets of at most the MTU, reassembled in order", () => {
    const { blePackets, BleReassembler } = loadBle(undefined);
    const message = Uint8Array.from({ length: 700 }, (_, i) => (i * 7) % 256);
    for (const mtu of [20, 156, 247]) {
        const packets = blePackets(message, mtu);
        assert.ok(
            packets.every((p) => p.length <= mtu),
            `mtu ${mtu}`,
        );
        assert.equal(hex(packets[0].subarray(0, 5)), "05" + "0000" + "02bc"); // 700 = 0x02bc
        assert.equal(hex(packets[1].subarray(0, 3)), "050001");
        const carried = packets.reduce((n, p, i) => n + p.length - (i === 0 ? 5 : 3), 0);
        assert.equal(carried, message.length);
        const reassembler = new BleReassembler();
        let out = null;
        for (const packet of packets) {
            assert.equal(out, null);
            out = reassembler.feed(packet);
        }
        assert.equal(hex(out), hex(message));
    }
    // An empty message is one packet of its header; the reassembler skips a probe answer and
    // refuses a packet out of order.
    assert.equal(hex(blePackets(new Uint8Array(0), 20)[0]), "0500000000");
    assert.equal(blePackets(new Uint8Array(0), 20).length, 1);
    const reassembler = new BleReassembler();
    assert.equal(reassembler.feed(Uint8Array.of(0x08, 0, 0, 0, 1, 156)), null);
    assert.equal(hex(reassembler.feed(Uint8Array.of(0x05, 0, 0, 0, 2, 0x90, 0x00))), "9000");
    assert.equal(reassembler.feed(Uint8Array.of(0x05, 0, 0, 0, 4, 1, 2)), null);
    assert.throws(() => reassembler.feed(Uint8Array.of(0x05, 0, 2, 3, 4)), /out of order/);
});

test("APDUs: get version, get public key, signing in 250-byte chunks, the status words", async () => {
    const { bleGetVersion, bleGetPublicKey, bleSign, bleRequest, BleStatusError } = loadBle(undefined);
    const seen = [];
    const answers = [];
    const link = {
        exchange: async (apdu) => {
            seen.push(Uint8Array.from(apdu));
            return answers.shift();
        },
    };
    answers.push(Uint8Array.of(2, 4, 3, 0x90, 0x00));
    assert.equal(await bleGetVersion(link), "2.4.3");
    assert.equal(hex(seen.pop()), "8006000000");

    const key = new Uint8Array(32).fill(7);
    answers.push(concat(key, Uint8Array.of(0x90, 0x00)));
    assert.equal(hex(await bleGetPublicKey(link, CLASSIC_PATH)), hex(key));
    assert.equal(hex(seen.pop()), "8004005714" + hex(pathBytes(CLASSIC_PATH)));
    // The ML-DSA-65 key at the same path: P1 40, the same data.
    const quantumKey = new Uint8Array(1952).fill(8);
    answers.push(concat(quantumKey, Uint8Array.of(0x90, 0x00)));
    assert.equal(hex(await bleGetPublicKey(link, CLASSIC_PATH, "ml-dsa-65")), hex(quantumKey));
    assert.equal(hex(seen.pop()), "8004405714" + hex(pathBytes(CLASSIC_PATH)));
    await assert.rejects(bleGetPublicKey(link, CLASSIC_PATH, "secp256k1"), /Unknown key type/);
    assert.equal(seen.length, 0, "an unknown key type sends nothing");

    // 20 bytes of path and 600 of payload: 250, 250 and 120, P1 80 on the last chunk only.
    const payload = Uint8Array.from({ length: 600 }, (_, i) => i & 0xff);
    const signature = new Uint8Array(64).fill(9);
    answers.push(Uint8Array.of(0x90, 0x00), Uint8Array.of(0x90, 0x00), concat(signature, Uint8Array.of(0x90, 0x00)));
    const progress = [];
    const signed = await bleSign(link, "transaction", CLASSIC_PATH, payload, {
        onProgress: (sent, total) => progress.push([sent, total]),
    });
    assert.equal(hex(signed), hex(signature));
    const chunks = seen.splice(-3);
    assert.deepEqual(
        chunks.map((apdu) => [hex(apdu.subarray(0, 5)), apdu.length - 5]),
        [
            ["80020057fa", 250],
            ["80020057fa", 250],
            ["80028057" + "78", 120],
        ],
    );
    assert.equal(hex(concat(...chunks.map((apdu) => apdu.subarray(5)))), hex(concat(pathBytes(CLASSIC_PATH), payload)));
    assert.deepEqual(progress, [
        [1, 3],
        [2, 3],
        [3, 3],
    ]);
    // For the ML-DSA-65 key every chunk carries bit 0x40: P1 40, 40, then C0 on the last.
    const quantumSignature = new Uint8Array(3309).fill(4);
    answers.push(
        Uint8Array.of(0x90, 0x00),
        Uint8Array.of(0x90, 0x00),
        concat(quantumSignature, Uint8Array.of(0x90, 0x00)),
    );
    const quantumSigned = await bleSign(link, "nep366", CLASSIC_PATH, payload, { keyType: "ml-dsa-65" });
    assert.equal(quantumSigned.length, 3309);
    assert.deepEqual(
        seen.splice(-3).map((apdu) => hex(apdu.subarray(0, 4))),
        ["80084057", "80084057", "8008c057"],
    );
    answers.push(Uint8Array.of(0x90, 0x00));
    await assert.rejects(bleSign(link, "nep413", CLASSIC_PATH, new Uint8Array(10)), /not a signature/);
    assert.equal(seen.pop()[1], 0x07);
    answers.push(Uint8Array.of(0x90, 0x00));
    await assert.rejects(bleSign(link, "nep366", CLASSIC_PATH, new Uint8Array(10)), /not a signature/);
    assert.equal(seen.pop()[1], 0x08);

    // A status word other than 9000 is the phone's verdict, in the camera transfer's words.
    answers.push(Uint8Array.of(0x69, 0x85));
    const rejected = await bleGetVersion(link).catch((error) => error);
    assert.ok(rejected instanceof BleStatusError);
    assert.equal(rejected.status, 0x6985);
    assert.equal(rejected.message, "NEAR Signer: rejected on the phone");
    answers.push(Uint8Array.of(0xb0, 0x0d));
    await assert.rejects(bleGetVersion(link), { status: 0xb00d, message: /not the phone's key/ });

    // bleRequest sends get version first, then the request itself, with the key type's bit.
    answers.push(Uint8Array.of(2, 4, 3, 0x90, 0x00), concat(new Uint8Array(1952).fill(1), Uint8Array.of(0x90, 0x00)));
    const requested = await bleRequest(link, { kind: "publicKey", path: CLASSIC_PATH, keyType: "ml-dsa-65" });
    assert.equal(requested.length, 1952);
    assert.deepEqual(
        seen.splice(-2).map((apdu) => hex(apdu.subarray(0, 4))),
        ["80060000", "80044057"],
    );
    answers.push(Uint8Array.of(2, 4, 3, 0x90, 0x00), concat(signature, Uint8Array.of(0x90, 0x00)));
    await bleRequest(link, { kind: "nep413", path: CLASSIC_PATH, payload: new Uint8Array(10) });
    assert.deepEqual(
        seen.splice(-2).map((apdu) => hex(apdu.subarray(0, 4))),
        ["80060000", "80078057"],
        "ed25519 is the default: no bit",
    );
    answers.push(Uint8Array.of(2, 4, 3, 0x90, 0x00));
    await assert.rejects(bleRequest(link, { kind: "version", path: CLASSIC_PATH }), /Not a signing request/);
});

test("bleAvailable follows navigator.bluetooth", () => {
    assert.equal(loadBle({}).bleAvailable(), false);
    assert.equal(loadBle({ bluetooth: {} }).bleAvailable(), true);
});

// MARK: - Against the simulator

let sim = null;

before(async () => {
    if (!fs.existsSync(SIM)) {
        throw new Error(`${SIM} is not built: swift build --product near-signer-sim (or set NEAR_SIGNER_SIM)`);
    }
    sim = spawn(SIM, ["--ble-packets", "--port", String(PORT), "--auto-approve"], {
        stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    let timer;
    await new Promise((resolve, reject) => {
        sim.stdout.on("data", (chunk) => {
            output += chunk;
            if (/listening on/.test(output)) resolve();
        });
        sim.stderr.on("data", (chunk) => (output += chunk));
        sim.on("exit", (code) => reject(new Error(`near-signer-sim exited with ${code}: ${output.slice(-400)}`)));
        timer = setTimeout(() => reject(new Error(`near-signer-sim did not start: ${output.slice(-400)}`)), 15000);
    }).finally(() => clearTimeout(timer));
});

after(() => {
    sim?.kill();
});

test("the simulator over fake Bluetooth: version, the classic key, a transfer, a NEP-413 message", async () => {
    const fake = makeFakeBluetooth({ port: PORT });
    const { bleConnect, bleRequest, bleGetVersion, BleStatusError } = loadBle({
        bluetooth: fake.bluetooth,
    });
    const statuses = [];
    const link = await bleConnect({ onStatus: (text) => statuses.push(text) });
    try {
        assert.equal(link.name, "NEAR Signer");
        assert.equal(link.mtu, 156, "the simulator's packet size");
        assert.match(statuses.join(" | "), /Connecting to NEAR Signer/);
        assert.equal(await bleGetVersion(link), "2.4.3");

        const key = await bleRequest(link, { kind: "publicKey", path: CLASSIC_PATH });
        assert.equal(key.length, 32);
        assert.equal(hex(key), hex(base58Decode(CLASSIC_KEY.slice("ed25519:".length))));

        const tx = Uint8Array.from(Buffer.from(TRANSFER_TX, "base64"));
        const before = fake.stats.signApdus;
        const signature = await bleRequest(link, { kind: "transaction", path: CLASSIC_PATH, payload: tx });
        assert.equal(signature.length, 64);
        assert.equal(fake.stats.signApdus - before, 1, "a transfer fits one chunk");
        assert.ok(await verifyEd25519(key, await sha256(tx), signature), "the transfer's signature verifies");

        const payload = nep413Payload({
            message: "hello from the executor",
            recipient: "app.near",
            nonce: new Uint8Array(32).fill(5),
        });
        const messageSignature = await bleRequest(link, { kind: "nep413", path: CLASSIC_PATH, payload });
        assert.ok(await verifyEd25519(key, await sha256(concat(NEP413_PREFIX, payload)), messageSignature));

        // A transaction whose key is not the phone's at that path: B00D, as the phone's verdict.
        const other = buildTransaction({
            signerId: "alice.testnet",
            publicKey: "ed25519:11111111111111111111111111111111",
            nonce: 1n,
            receiverId: "bob.testnet",
            blockHash: new Uint8Array(32),
            actions: [{ type: "Transfer", params: { deposit: 1n } }],
        });
        const refused = await bleRequest(link, { kind: "transaction", path: CLASSIC_PATH, payload: other }).catch(
            (e) => e,
        );
        assert.ok(refused instanceof BleStatusError, `expected a status error, got ${refused}`);
        assert.equal(refused.status, 0xb00d);

        // A 2 KB payload goes as nine chunks, acknowledged one by one.
        const big = buildTransaction({
            signerId: "alice.testnet",
            publicKey: CLASSIC_KEY,
            nonce: 2n,
            receiverId: "bob.testnet",
            blockHash: new Uint8Array(32).fill(3),
            actions: [
                {
                    type: "FunctionCall",
                    params: { methodName: "m", args: new Uint8Array(2000).fill(0x20), gas: 1n, deposit: 0n },
                },
            ],
        });
        const chunksBefore = fake.stats.signApdus;
        const bigSignature = await bleRequest(link, { kind: "transaction", path: CLASSIC_PATH, payload: big });
        assert.equal(fake.stats.signApdus - chunksBefore, Math.ceil((20 + big.length) / 250));
        assert.equal(fake.stats.unacknowledged, 0, "standard chunks: every write acknowledged");
        assert.ok(await verifyEd25519(key, await sha256(big), bigSignature));
    } finally {
        link.disconnect();
    }
    // The link is closed: an exchange after the disconnect fails instead of hanging.
    await assert.rejects(bleGetVersion(link), /closed|disconnected/);
    fake.close();
});

test("the quantum-safe key, P1 bit 0x40 at the classic path: ML-DSA-65 key, signature and refusals", async () => {
    const expected = execFileSync(SIM, ["pubkey", "--key-type", "ml-dsa-65"], { stdio: ["ignore", "pipe", "ignore"] })
        .toString()
        .trim();
    assert.match(expected, /^ml-dsa-65:/, "near-signer-sim pubkey --key-type ml-dsa-65");
    const fake = makeFakeBluetooth({ port: PORT });
    const { bleConnect, bleRequest, BleStatusError } = loadBle({ bluetooth: fake.bluetooth });
    const link = await bleConnect();
    try {
        const key = await bleRequest(link, { kind: "publicKey", path: CLASSIC_PATH, keyType: "ml-dsa-65" });
        assert.equal(key.length, 1952);
        const keyText = publicKeyString(key);
        assert.equal(keyText, expected, "the key the simulator prints for its ML-DSA-65 tree");
        assert.equal(fake.stats.mlDsa65Apdus, 1, "get public key with P1 40");

        const tx = buildTransaction({
            signerId: "alice.testnet",
            publicKey: keyText,
            nonce: 7n,
            receiverId: "bob.testnet",
            blockHash: new Uint8Array(32).fill(9),
            actions: [{ type: "Transfer", params: { deposit: 10n ** 24n } }],
        });
        const chunks = Math.ceil((20 + tx.length) / 250);
        assert.ok(chunks > 1, "a transaction naming an ML-DSA-65 key takes several chunks");
        const signApdus = fake.stats.signApdus;
        const signature = await bleRequest(link, {
            kind: "transaction",
            path: CLASSIC_PATH,
            keyType: "ml-dsa-65",
            payload: tx,
        });
        assert.equal(signature.length, 3309, "an ML-DSA-65 signature");
        assert.equal(fake.stats.signApdus - signApdus, chunks);
        assert.equal(fake.stats.mlDsa65Apdus, 1 + chunks, "every chunk with the bit");

        const payload = nep413Payload({ message: "quantum", recipient: "app.near", nonce: new Uint8Array(32) });
        const messageSignature = await bleRequest(link, {
            kind: "nep413",
            path: CLASSIC_PATH,
            keyType: "ml-dsa-65",
            payload,
        });
        assert.equal(messageSignature.length, 3309);

        // The tree and the transaction's key must agree: the ed25519 tree refuses the transaction
        // that names the ML-DSA-65 key, and the ML-DSA-65 tree one that names the ed25519 key.
        const refused = await bleRequest(link, { kind: "transaction", path: CLASSIC_PATH, payload: tx }).catch(
            (e) => e,
        );
        assert.ok(refused instanceof BleStatusError, `expected a status error, got ${refused}`);
        assert.equal(refused.status, 0xb00d);
        const classicTx = Uint8Array.from(Buffer.from(TRANSFER_TX, "base64"));
        const crossed = await bleRequest(link, {
            kind: "transaction",
            path: CLASSIC_PATH,
            keyType: "ml-dsa-65",
            payload: classicTx,
        }).catch((e) => e);
        assert.ok(crossed instanceof BleStatusError, `expected a status error, got ${crossed}`);
        assert.equal(crossed.status, 0xb00d);
    } finally {
        link.disconnect();
    }
    fake.close();
});
