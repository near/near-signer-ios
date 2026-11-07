// NEAR Signer over Bluetooth, for the near-connect executor: Web Bluetooth against the phone's
// Ledger Nano X emulation (README.md "Protocol"). The phone advertises the Nano X service and
// speaks the NEAR Ledger app's APDUs, so this is the Ledger protocol with one bit added (the
// key type, below): Ledger framing on the GATT characteristics, standard 250-byte chunks for
// signing, the Ledger app's status words. The answers are typed by their length, as the camera transfer's are: a 32-byte
// ed25519 or 1952-byte ML-DSA-65 key, a 64-byte ed25519 or 3309-byte ML-DSA-65 signature. Fast
// mode (the `80 20` capabilities, extended APDUs, unacknowledged writes) is not used: a request
// big enough to need it is better off as QR codes, and near-signer-host has it for the terminal.
//
// Ported from near-connect's own Ledger executor (github.com/near/near-connect-ledger: the
// functions transportConnect, bleExchange, getPublicKey and sign), which host/compat/ runs against
// the simulator; this is the Bluetooth part alone, with no USB, HID or app opening, and the device
// chooser asks for the Nano X service only. A plain script like executor/main.js:
// scripts/build-optical-executor.mjs bundles it after optical.mjs, whose pathBytes and
// statusMessage it uses, and host/optical/test_ble.mjs runs it in Node against
// near-signer-sim --ble-packets through a fake navigator.bluetooth.
//
// The one thing added to the Ledger app's commands: P1's bit 0x40 asks for the ML-DSA-65 key at
// the path instead of the ed25519 one (the two trees of the recovery phrase share their paths,
// NEP-649), on get public key and on every chunk of a signing request. Without it the commands
// are a Ledger's, byte for byte.
//
// What main.js uses: bleAvailable(), bleConnect({ onStatus }) for a link, bleRequest(link,
// { kind, path, keyType, payload, onProgress }) for the answer bytes, link.disconnect(), and
// BleStatusError (the phone's verdict, with the status word) to tell it from a link that failed.

/* exported bleAvailable, bleConnect, bleRequest, BleStatusError */

const BLE_SERVICE = "13d63400-2c97-0004-0000-4c6564676572";
const BLE_NOTIFY = "13d63400-2c97-0004-0001-4c6564676572";
const BLE_WRITE = "13d63400-2c97-0004-0002-4c6564676572";
/// Answered with `08 00 00 00 01 <packet size>`: the most bytes one packet may carry.
const BLE_MTU_PROBE = Uint8Array.of(0x08, 0, 0, 0, 0);
const BLE_DEFAULT_MTU = 20;
const BLE_DATA_TAG = 0x05;
const BLE_PROBE_TIMEOUT = 5000;

const APDU_CLA = 0x80;
const APDU_INS = { version: 0x06, publicKey: 0x04, transaction: 0x02, nep413: 0x07, nep366: 0x08 };
/// P2 of the NEAR app's commands: "W", as near-connect and near-ledger-rs send it.
const APDU_NETWORK = 0x57;
const APDU_CHUNK = 250;
const APDU_P1_LAST = 0x80;
/// P1's bit for the ML-DSA-65 tree, next to `00`/`01` (display/silent) of get public key and
/// `00`/`80` (more/last) of the signing chunks.
const APDU_P1_ML_DSA_65 = 0x40;
const STATUS_OK = 0x9000;

const KEY_LENGTHS = [32, 1952];
const SIGNATURE_LENGTHS = [64, 3309];

/// An answer other than 9000 from the phone: `status` is the word, the message its meaning, with
/// the same words the camera transfer uses for the same status.
class BleStatusError extends Error {
    constructor(status) {
        super(`NEAR Signer: ${statusMessage(status)}`);
        this.name = "BleStatusError";
        this.status = status;
    }
}

/// Whether this browser has Web Bluetooth at all (Chrome, Edge and their relatives; Safari and
/// Firefox have none). near-connect lets the executor's iframe use it when the manifest says
/// "bluetooth": true under permissions; without that, the device chooser throws a SecurityError,
/// which bleConnect turns into words.
function bleAvailable() {
    return typeof navigator !== "undefined" && Boolean(navigator.bluetooth);
}

/// The Ledger framing of one message: `05 | seq u16 BE | data`, the first packet with the
/// message's length as u16 BE after the sequence number, each packet at most `mtu` bytes. An
/// empty message is one packet of its header.
function blePackets(message, mtu) {
    const packets = [];
    let offset = 0;
    for (let seq = 0; offset < message.length || seq === 0; seq++) {
        const header = seq === 0 ? 5 : 3;
        const take = Math.min(message.length - offset, mtu - header);
        const packet = new Uint8Array(header + take);
        packet[0] = BLE_DATA_TAG;
        packet[1] = seq >> 8;
        packet[2] = seq & 0xff;
        if (seq === 0) {
            packet[3] = message.length >> 8;
            packet[4] = message.length & 0xff;
        }
        packet.set(message.subarray(offset, offset + take), header);
        offset += take;
        packets.push(packet);
    }
    return packets;
}

/// The other direction: packets in, the message out once it is whole. Packets with another tag
/// (a late answer to the probe) are ignored; a sequence number out of order is an error, as the
/// link has lost a packet then.
class BleReassembler {
    constructor() {
        this.reset();
    }

    reset() {
        this.message = null;
        this.offset = 0;
        this.seq = 0;
    }

    /// The whole message after this packet, or null while more are needed.
    feed(packet) {
        if (packet.length < 3 || packet[0] !== BLE_DATA_TAG) return null;
        const seq = (packet[1] << 8) | packet[2];
        if (seq !== this.seq) {
            const expected = this.seq;
            this.reset();
            throw new Error(`Bluetooth packet ${seq} arrived out of order (expected ${expected}).`);
        }
        let start = 3;
        if (seq === 0) {
            if (packet.length < 5) throw new Error("Bluetooth packet too short.");
            this.message = new Uint8Array((packet[3] << 8) | packet[4]);
            this.offset = 0;
            start = 5;
        }
        const take = Math.min(this.message.length - this.offset, packet.length - start);
        this.message.set(packet.subarray(start, start + take), this.offset);
        this.offset += take;
        this.seq += 1;
        if (this.offset < this.message.length) return null;
        const message = this.message;
        this.reset();
        return message;
    }
}

/// The chooser's refusal in words: cancelled, nothing to choose, or not allowed here.
function chooserError(error) {
    const why = error instanceof Error ? error.message : String(error);
    if (error?.name === "NotFoundError") {
        return "No phone chosen. Open NEAR Signer on the iPhone, with Bluetooth on, and choose it in the browser's list.";
    }
    if (error?.name === "SecurityError" && /polic|disallowed|not allowed/i.test(why)) {
        return 'Bluetooth is not allowed here: this wallet\'s manifest needs "bluetooth": true under permissions. Use the camera instead.';
    }
    return `Bluetooth: ${why}`;
}

/// Connects to the phone: the browser's device chooser (Web Bluetooth shows it only from a click),
/// the GATT server, the Nano X service's characteristics, notifications, and the MTU probe.
/// Resolves with a link: `exchange(apdu)` sends one APDU and resolves with the whole answer
/// (data and status word), `disconnect()` ends it, `name` and `mtu` say what was found. `onStatus`
/// hears what is happening, in words for the screen. Rejects with the reason in words when the
/// chooser was cancelled, the device is not a NEAR Signer, or the phone does not answer.
async function bleConnect({ onStatus = () => {} } = {}) {
    if (!bleAvailable()) throw new Error("This browser has no Web Bluetooth. Use the camera instead.");
    let device;
    try {
        device = await navigator.bluetooth.requestDevice({ filters: [{ services: [BLE_SERVICE] }] });
    } catch (error) {
        throw new Error(chooserError(error), { cause: error });
    }
    const name = device.name || "the phone";
    onStatus(`Connecting to ${name}…`);

    // Packets arrive as notifications; an exchange takes them one at a time, so none is lost
    // when the phone answers faster than the reassembly runs. A disconnect ends the wait.
    const queue = [];
    let waiting = null;
    let gone = null;
    const onPacket = (event) => {
        const value = event.target.value;
        const packet = new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice();
        if (waiting) {
            const { resolve } = waiting;
            waiting = null;
            resolve(packet);
        } else {
            queue.push(packet);
        }
    };
    const nextPacket = () => {
        if (queue.length > 0) return Promise.resolve(queue.shift());
        if (gone) return Promise.reject(gone);
        return new Promise((resolve, reject) => {
            waiting = { resolve, reject };
        });
    };
    const onDisconnected = () => {
        gone = new Error("The phone disconnected. Keep NEAR Signer open on it and connect again.");
        if (waiting) {
            const { reject } = waiting;
            waiting = null;
            reject(gone);
        }
    };

    let notify = null;
    let write = null;
    const disconnect = () => {
        device.removeEventListener("gattserverdisconnected", onDisconnected);
        if (notify) {
            notify.removeEventListener("characteristicvaluechanged", onPacket);
            notify.stopNotifications().catch(() => {});
        }
        if (device.gatt.connected) device.gatt.disconnect();
        if (!gone) gone = new Error("The Bluetooth link was closed.");
    };

    try {
        device.addEventListener("gattserverdisconnected", onDisconnected);
        const server = await device.gatt.connect();
        const service = await server.getPrimaryService(BLE_SERVICE);
        const characteristics = await service.getCharacteristics();
        const find = (uuid) => characteristics.find((c) => c.uuid.toLowerCase() === uuid) ?? null;
        write = find(BLE_WRITE);
        notify = find(BLE_NOTIFY);
        if (!write || !notify) throw new Error(`${name} does not speak the Ledger protocol.`);
        notify.addEventListener("characteristicvaluechanged", onPacket);
        await notify.startNotifications();
        const writePacket = (packet) =>
            typeof write.writeValueWithResponse === "function"
                ? write.writeValueWithResponse(packet)
                : write.writeValue(packet);

        // The MTU probe: the phone says how long a packet may be; without an answer, the
        // smallest size every device takes.
        await writePacket(BLE_MTU_PROBE);
        const reply = await withTimeout(nextPacket(), BLE_PROBE_TIMEOUT, `${name} does not answer.`);
        const mtu = reply[0] === 0x08 && reply.length > 5 && reply[5] > 5 ? reply[5] : BLE_DEFAULT_MTU;

        const exchange = async (apdu) => {
            if (gone) throw gone;
            for (const packet of blePackets(apdu, mtu)) await writePacket(packet);
            const reassembler = new BleReassembler();
            for (;;) {
                const message = reassembler.feed(await nextPacket());
                if (message) return message;
            }
        };
        return { device, name, mtu, exchange, disconnect };
    } catch (error) {
        disconnect();
        throw error;
    }
}

function withTimeout(promise, ms, message) {
    let timer;
    return Promise.race([
        promise,
        new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error(message)), ms);
        }),
    ]).finally(() => clearTimeout(timer));
}

/// One command: `CLA INS P1 P2 Lc data`, the answer's data without the status word, or a
/// BleStatusError for any status but 9000.
async function bleSend(link, ins, p1, p2, data = new Uint8Array(0)) {
    const apdu = new Uint8Array(5 + data.length);
    apdu.set([APDU_CLA, ins, p1, p2, data.length]);
    apdu.set(data, 5);
    const response = await link.exchange(apdu);
    if (response.length < 2) throw new Error("The phone's answer is too short to hold a status word.");
    const status = (response[response.length - 2] << 8) | response[response.length - 1];
    if (status !== STATUS_OK) throw new BleStatusError(status);
    return response.subarray(0, response.length - 2);
}

/// `80 06`: "2.4.3", what the phone reports so that every host enables every feature.
async function bleGetVersion(link) {
    const version = await bleSend(link, APDU_INS.version, 0, 0);
    if (version.length < 3) throw new Error("The phone's version answer is too short.");
    return `${version[0]}.${version[1]}.${version[2]}`;
}

/// The tree `keyType` names, as P1's bit: "ml-dsa-65" sets it, "ed25519" leaves P1 a Ledger's.
function keyTypeBit(keyType) {
    if (keyType === "ml-dsa-65") return APDU_P1_ML_DSA_65;
    if (keyType === "ed25519") return 0;
    throw new Error(`Unknown key type: ${keyType}`);
}

/// `80 04` with P1 `00` (`40` for the ML-DSA-65 key): the phone shows the address and asks
/// before sharing it. The key as raw bytes, 32 (ed25519) or 1952 (ML-DSA-65).
async function bleGetPublicKey(link, path, keyType = "ed25519") {
    const key = await bleSend(link, APDU_INS.publicKey, keyTypeBit(keyType), APDU_NETWORK, pathBytes(path));
    if (!KEY_LENGTHS.includes(key.length)) {
        throw new Error(`The phone answered with ${key.length} bytes, which is not a public key.`);
    }
    return key;
}

/// `80 02`, `80 07` or `80 08` by `kind` (transaction, nep413, nep366): the path and the payload,
/// in chunks of 250 bytes, P1 `80` on the last, which the phone answers with the signature once
/// the person approved: 64 bytes (ed25519) or 3309 (ML-DSA-65). Every chunk carries the key
/// type's bit (`40`/`C0` for ML-DSA-65). `onProgress(sent, total)` after each chunk.
async function bleSign(link, kind, path, payload, { keyType = "ed25519", onProgress = () => {} } = {}) {
    const ins = APDU_INS[kind];
    if (!ins || kind === "publicKey" || kind === "version") throw new Error(`Not a signing request: ${kind}`);
    const tree = keyTypeBit(keyType);
    const data = new Uint8Array(20 + payload.length);
    data.set(pathBytes(path));
    data.set(payload, 20);
    const total = Math.ceil(data.length / APDU_CHUNK);
    let result = null;
    for (let i = 0; i < total; i++) {
        const last = i === total - 1;
        result = await bleSend(
            link,
            ins,
            tree | (last ? APDU_P1_LAST : 0),
            APDU_NETWORK,
            data.subarray(i * APDU_CHUNK, (i + 1) * APDU_CHUNK),
        );
        onProgress(i + 1, total);
    }
    if (!SIGNATURE_LENGTHS.includes(result.length)) {
        throw new Error(`The phone answered with ${result.length} bytes, which is not a signature.`);
    }
    return result;
}

/// The request the camera transfer would carry, over the link instead: the public key for
/// `publicKey`, the signature for the other kinds, from the `keyType` tree ("ed25519", the
/// default, or "ml-dsa-65"). Get version goes first, as every host sends it: it confirms the link
/// speaks the NEAR app before the phone is asked anything.
async function bleRequest(link, { kind, path, keyType = "ed25519", payload = new Uint8Array(0), onProgress }) {
    await bleGetVersion(link);
    return kind === "publicKey"
        ? bleGetPublicKey(link, path, keyType)
        : bleSign(link, kind, path, payload, { keyType, onProgress });
}
