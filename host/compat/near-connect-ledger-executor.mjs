#!/usr/bin/env node
// Runs the real near-connect Ledger executor (github.com/near/near-connect-ledger) against
// near-signer-sim in --ble-packets mode. A fake `navigator.bluetooth` forwards every GATT write
// to the simulator and turns its replies into `characteristicvaluechanged` events, so the
// executor's own MTU negotiation, BLE framing, chunking and APDUs are exercised unchanged.
//
//   near-signer-sim --ble-packets --port 9998 --auto-approve &
//   node host/compat/near-connect-ledger-executor.mjs [--executor FILE_OR_URL] [--port 9998]
//        [--expect-fast yes|no]
//
// It also signs a 200 KB contract deployment and reports how many signing APDUs that took.
// An executor that uses NEAR Signer's fast mode needs a handful of 32 KiB extended APDUs; the
// upstream one sends ~1,600 short ones. --expect-fast asserts which one.
//
// No npm dependencies. Exits non-zero on failure.

import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import vm from "node:vm";

const args = process.argv.slice(2);
const option = (name, fallback) => {
    const index = args.indexOf(name);
    return index >= 0 ? args[index + 1] : fallback;
};
const executorSource = option(
    "--executor",
    "https://raw.githubusercontent.com/near/near-connect-ledger/main/ledger-executor.js",
);
const port = Number(option("--port", "9998"));
const verbose = args.includes("--verbose");
const expectFast = option("--expect-fast", null);

// Test data: a transfer built by near-api-js for the BIP-39 test phrase (see Tests/NearSignerCoreTests/Fixtures.swift).
const EXPECTED_PUBLIC_KEY = "ed25519:EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz";
const TRANSFER_TX =
    "DQAAAGFsaWNlLnRlc3RuZXQAxXHjPi42wsco1hfqd6iOIyDIaX6si0Y638ASi5aCXL8HAAAAAAAAAAsAAABib2IudGVzdG5ldDlKvrNecHYJ3o9ztj1DvRo3b/5nk1yqaJN90pvATmc8AQAAAAMAAIBxZDO2KaM9AQAAAAAA";

async function loadExecutor() {
    if (/^https?:/.test(executorSource)) {
        const response = await fetch(executorSource);
        if (!response.ok) throw new Error(`download failed: ${response.status}`);
        return await response.text();
    }
    return fs.readFileSync(executorSource, "utf8");
}

const BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
function base58Decode(text) {
    let value = 0n;
    for (const char of text) value = value * 58n + BigInt(BASE58.indexOf(char));
    const bytes = [];
    while (value > 0n) {
        bytes.unshift(Number(value & 0xffn));
        value >>= 8n;
    }
    for (const char of text) {
        if (char === "1") bytes.unshift(0);
        else break;
    }
    return Uint8Array.from(bytes);
}
function verifyEd25519(publicKey, message, signature) {
    const spki = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(publicKey)]);
    const key = crypto.createPublicKey({ key: spki, format: "der", type: "spki" });
    return crypto.verify(null, Buffer.from(message), key, Buffer.from(signature));
}
const sha256 = (bytes) => new Uint8Array(crypto.createHash("sha256").update(bytes).digest());

/// Fake Web Bluetooth device whose GATT server is near-signer-sim.
function makeFakeBluetooth() {
    const socket = net.connect({ host: "127.0.0.1", port });
    let buffer = Buffer.alloc(0);
    const listeners = [];
    const deviceListeners = [];
    let connected = false;
    const notify = (value) => {
        if (!connected) return;
        for (const listener of listeners) listener({ target: { value } });
    };
    socket.on("data", (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        while (buffer.length >= 2) {
            const length = buffer.readUInt16BE(0);
            if (buffer.length < 2 + length) break;
            const packet = new Uint8Array(buffer.subarray(2, 2 + length));
            buffer = buffer.subarray(2 + length);
            notify(new DataView(packet.buffer, packet.byteOffset, packet.byteLength));
        }
    });
    const ready = new Promise((resolve, reject) => {
        socket.once("connect", resolve);
        socket.once("error", reject);
    });
    const stats = {
        signApdus: 0,
        maxApdu: 0,
        unacknowledged: 0,
        acknowledged: 0,
        run: 0,
        longestRun: 0,
    };
    const send = (data, acknowledged) => {
        const bytes = Buffer.from(data.buffer ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : data);
        // Each message ends with waiting for the device's reply, which syncs the queue.
        if (bytes[0] === 0x05 && bytes[1] === 0 && bytes[2] === 0) stats.run = 0;
        if (acknowledged) {
            stats.acknowledged++;
            stats.run = 0;
        } else {
            stats.unacknowledged++;
            stats.run++;
            stats.longestRun = Math.max(stats.longestRun, stats.run);
        }
        // First packet of a message: 05 | seq 0000 | length | APDU…
        if (bytes[0] === 0x05 && bytes[1] === 0 && bytes[2] === 0 && bytes.length > 6) {
            const length = bytes.readUInt16BE(3);
            if (bytes[5] === 0x80 && [0x02, 0x07, 0x08].includes(bytes[6])) stats.signApdus++;
            stats.maxApdu = Math.max(stats.maxApdu, length);
        }
        const header = Buffer.alloc(2);
        header.writeUInt16BE(bytes.length);
        socket.write(Buffer.concat([header, bytes]));
    };
    const service = "13d63400-2c97-0004-0000-4c6564676572";
    const writeChar = {
        uuid: "13d63400-2c97-0004-0002-4c6564676572",
        properties: { write: true, writeWithoutResponse: true },
        writeValueWithoutResponse: async (data) => send(data, false),
        writeValueWithResponse: async (data) => send(data, true),
        writeValue: async (data) => send(data, true),
    };
    const notifyChar = {
        uuid: "13d63400-2c97-0004-0001-4c6564676572",
        properties: { notify: true },
        addEventListener: (_name, listener) => listeners.push(listener),
        removeEventListener: () => {},
        startNotifications: async () => {},
        stopNotifications: async () => {},
    };
    const device = {
        name: "NEAR Signer",
        addEventListener: (name, listener) => {
            if (name === "gattserverdisconnected") deviceListeners.push(listener);
        },
        gatt: {
            get connected() {
                return connected;
            },
            connect: async () => {
                await ready;
                connected = true;
            },
            disconnect: () => {
                if (!connected) return;
                connected = false;
                // Chrome fires the event asynchronously.
                setTimeout(() => {
                    for (const listener of deviceListeners) listener();
                }, 0);
            },
            getPrimaryServices: async () => [
                { uuid: service, getCharacteristics: async () => [writeChar, notifyChar] },
            ],
        },
    };
    return {
        bluetooth: {
            requestDevice: async ({ filters }) => {
                if (!filters.some((f) => f.services.includes(service))) throw new Error("Nano X service not requested");
                return device;
            },
        },
        close: () => socket.destroy(),
        stats,
    };
}

async function main() {
    const source = await loadExecutor();
    const fake = makeFakeBluetooth();
    let registeredWallet = null;
    const window = {
        addEventListener: () => {},
        parent: null,
        selector: {
            ready: (wallet) => {
                registeredWallet = wallet;
            },
            storage: { get: async () => null, set: async () => {}, remove: async () => {}, keys: async () => [] },
            ui: { showIframe: async () => {}, hideIframe: async () => {} },
        },
    };
    window.parent = window;
    const context = vm.createContext({
        window,
        navigator: { bluetooth: fake.bluetooth },
        document: { getElementById: () => null, querySelectorAll: () => [] },
        console: verbose ? console : { log() {}, info() {}, warn() {}, error: console.error },
        setTimeout,
        clearTimeout,
        TextEncoder,
        TextDecoder,
        Uint8Array,
        DataView,
        fetch,
    });
    // Expose the executor's internal functions to this harness.
    vm.runInContext(
        source +
            "\n;globalThis.__api = { transportConnect, openNearApplication, getVersion, getPublicKey, sign, TRANSPORT_WEB_BLE };",
        context,
    );
    const api = context.__api;
    if (!registeredWallet) throw new Error("executor did not call selector.ready");

    await api.transportConnect(api.TRANSPORT_WEB_BLE);
    await api.openNearApplication();
    console.log("app version reported:", await api.getVersion());

    const publicKey = await api.getPublicKey("44'/397'/0'/0'/1'");
    const expectedKey = base58Decode(EXPECTED_PUBLIC_KEY.slice("ed25519:".length));
    if (Buffer.compare(Buffer.from(publicKey), Buffer.from(expectedKey)) !== 0) throw new Error("public key mismatch");
    console.log("public key OK");

    const tx = Uint8Array.from(Buffer.from(TRANSFER_TX, "base64"));
    const txSignature = await api.sign(tx, "44'/397'/0'/0'/1'");
    if (!verifyEd25519(expectedKey, sha256(tx), txSignature)) throw new Error("transaction signature invalid");
    console.log("transaction signature OK");

    // NEP-413 the way LedgerWallet.signMessage does it: tag prefix, which sign() strips before INS 0x07.
    const message = new TextEncoder().encode("hello from near-connect");
    const payload = new Uint8Array(4 + message.length + 32 + 4 + 8 + 1);
    const view = new DataView(payload.buffer);
    view.setUint32(0, message.length, true);
    payload.set(message, 4);
    payload.set(new Uint8Array(32).fill(5), 4 + message.length);
    view.setUint32(4 + message.length + 32, 8, true);
    payload.set(new TextEncoder().encode("app.near"), 4 + message.length + 36);
    const tag = Uint8Array.from([0x9d, 0x01, 0x00, 0x80]);
    const prefixed = new Uint8Array([...tag, ...payload]);
    const messageSignature = await api.sign(prefixed, "44'/397'/0'/0'/1'");
    if (!verifyEd25519(expectedKey, sha256(prefixed), messageSignature)) throw new Error("NEP-413 signature invalid");
    console.log("NEP-413 signature OK");

    // A 200 KB contract deployment.
    const code = new Uint8Array(200_000 + 8);
    code.set([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
    for (let i = 8; i < code.length; i++) code[i] = i & 0xff;
    const enc = (text) => new TextEncoder().encode(text);
    const u32 = (n) => {
        const b = new Uint8Array(4);
        new DataView(b.buffer).setUint32(0, n, true);
        return b;
    };
    const u64 = (n) => {
        const b = new Uint8Array(8);
        new DataView(b.buffer).setBigUint64(0, BigInt(n), true);
        return b;
    };
    const borshString = (text) => new Uint8Array([...u32(enc(text).length), ...enc(text)]);
    const deploy = new Uint8Array(
        [
            ...borshString("alice.testnet"),
            0,
            ...expectedKey,
            ...u64(7),
            ...borshString("alice.testnet"),
            ...new Uint8Array(32),
            ...u32(1),
            1,
            ...u32(code.length),
        ].concat(Array.from(code)),
    );
    const before = fake.stats.signApdus;
    const started = Date.now();
    const deploySignature = await api.sign(deploy, "44'/397'/0'/0'/1'");
    if (!verifyEd25519(expectedKey, sha256(deploy), deploySignature)) throw new Error("deployment signature invalid");
    const apdus = fake.stats.signApdus - before;
    const fast = fake.stats.maxApdu > 255 + 7;
    console.log(
        `deployment (${deploy.length} bytes) signature OK: ${apdus} signing APDUs, largest ${fake.stats.maxApdu} bytes,`,
        `${fast ? "fast mode" : "standard chunks"}, ${Date.now() - started} ms`,
    );
    if (expectFast === "yes" && !fast) throw new Error("expected fast mode");
    if (expectFast === "no" && fast) throw new Error("expected standard chunks");
    if (fast && fake.stats.unacknowledged === 0) throw new Error("fast mode should skip per-packet acknowledgements");
    if (fast && fake.stats.acknowledged === 0) throw new Error("fast mode must still acknowledge some packets");
    if (fast && fake.stats.longestRun > 3)
        throw new Error(`${fake.stats.longestRun} unacknowledged writes in a row (at most 3 expected)`);

    fake.close();
    console.log("near-connect Ledger executor: all checks passed");
    // The executor leaves its response timers running; don't wait minutes for them.
    process.exit(0);
}

main().catch((error) => {
    console.error("FAILED:", error);
    process.exit(1);
});
