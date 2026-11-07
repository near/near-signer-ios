// Camera transfer: the computer shows a request to NEAR Signer as a loop of QR codes, and the
// phone answers with one QR code. The format is specified in README.md ("Camera transfer").
//
// This file is the codec only, with no dependencies, for Node and browsers alike. The QR codes
// themselves are drawn by qr.mjs (terminal, canvas), the command line by near-signer-qr.mjs.

const FRAME_PREFIX = "NS1:";
const FRAME_HEADER = 19;
const FRAME_TYPE = 0x01;
const RESPONSE_TYPE = 0x02;
export const MAX_MESSAGE = 1_600_021;
export const MAX_FRAGMENT = 1200;
export const MAX_FRAGMENTS = 65535;

export const INSTRUCTIONS = { publicKey: 0x04, transaction: 0x02, nep413: 0x07, nep366: 0x08 };
const KINDS = Object.fromEntries(Object.entries(INSTRUCTIONS).map(([kind, ins]) => [ins, kind]));
/// Set on the instruction byte when the payload is sent as raw DEFLATE (RFC 1951), after its
/// length as u32.
export const COMPRESSED_FLAG = 0x80;
export const MAX_PAYLOAD = 1_600_000;

// MARK: - Text encodings

const BASE45 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

/// RFC 9285: two bytes become three characters, a final odd byte two.
export function base45Encode(bytes) {
    let out = "";
    for (let i = 0; i + 1 < bytes.length; i += 2) {
        let n = bytes[i] * 256 + bytes[i + 1];
        out += BASE45[n % 45];
        n = Math.floor(n / 45);
        out += BASE45[n % 45] + BASE45[Math.floor(n / 45)];
    }
    if (bytes.length % 2 === 1) {
        const n = bytes[bytes.length - 1];
        out += BASE45[n % 45] + BASE45[Math.floor(n / 45)];
    }
    return out;
}

/// Null for anything that is not base45 (a character outside the alphabet, a lone trailing
/// character, or a triplet above 65535).
export function base45Decode(text) {
    if (text.length % 3 === 1) return null;
    const out = new Uint8Array(Math.floor(text.length / 3) * 2 + (text.length % 3 === 2 ? 1 : 0));
    let o = 0;
    for (let i = 0; i < text.length; i += 3) {
        const c = BASE45.indexOf(text[i]);
        const e = BASE45.indexOf(text[i + 1]);
        if (c < 0 || e < 0) return null;
        if (i + 2 < text.length) {
            const d = BASE45.indexOf(text[i + 2]);
            if (d < 0) return null;
            const n = c + e * 45 + d * 45 * 45;
            if (n > 0xffff) return null;
            out[o++] = n >> 8;
            out[o++] = n & 0xff;
        } else {
            const n = c + e * 45;
            if (n > 0xff) return null;
            out[o++] = n;
        }
    }
    return out;
}

const BASE32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Crockford base32, upper case, no padding.
export function base32Encode(bytes) {
    let out = "";
    let bits = 0;
    let value = 0;
    for (const byte of bytes) {
        value = (value << 8) | byte;
        bits += 8;
        while (bits >= 5) {
            out += BASE32[(value >> (bits - 5)) & 31];
            bits -= 5;
        }
        value &= (1 << bits) - 1;
    }
    if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
    return out;
}

/// Lenient, for typed input: any case, spaces and hyphens ignored, I and L read as 1, O as 0.
/// Null on any other character.
export function base32Decode(text) {
    const clean = text.toUpperCase().replace(/[\s-]/g, "").replace(/[IL]/g, "1").replace(/O/g, "0");
    const out = new Uint8Array(Math.floor((clean.length * 5) / 8));
    let bits = 0;
    let value = 0;
    let o = 0;
    for (const char of clean) {
        const digit = BASE32.indexOf(char);
        if (digit < 0) return null;
        value = ((value << 5) | digit) & 0xffff;
        bits += 5;
        if (bits >= 8) {
            out[o++] = (value >> (bits - 8)) & 0xff;
            bits -= 8;
        }
    }
    return out;
}

/// The code in groups of five characters, as the phone shows it under the QR code.
export function grouped(text) {
    return text.match(/.{1,5}/g)?.join(" ") ?? "";
}

// MARK: - Integrity

const CRC_TABLE = new Uint32Array(256);
for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    CRC_TABLE[n] = c >>> 0;
}

/// CRC-32 (IEEE, as in zlib and PNG).
export function crc32(bytes) {
    let c = 0xffffffff;
    for (const byte of bytes) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
}

// MARK: - Fountain code

/// Which fragments frame `sequence` of a transfer combines. Frames below the fragment count are
/// the fragments themselves; the rest are the XOR of a pseudo-random choice both sides compute.
export function fountainIndexes(sessionId, sequence, fragmentCount) {
    // Even blocks of K frames carry the fragments in order, so every fragment passes by within 2K
    // frames whenever the phone starts watching; odd blocks mix them to fill in what was missed.
    if (Math.floor(sequence / fragmentCount) % 2 === 0) return [sequence % fragmentCount];
    const next = fountainGenerator(sessionId, sequence);
    const degree = solitonDegree(next(), fragmentCount);
    const indexes = Array.from({ length: fragmentCount }, (_, i) => i);
    for (let i = 0; i < degree; i++) {
        const j = i + (next() % (fragmentCount - i));
        [indexes[i], indexes[j]] = [indexes[j], indexes[i]];
    }
    return indexes.slice(0, degree);
}

/// How many fragments frame `sequence` mixes, from the generator's first draw only: cheap even
/// when the frame mixes thousands.
export function fountainDegree(sessionId, sequence, fragmentCount) {
    if (Math.floor(sequence / fragmentCount) % 2 === 0) return 1;
    return solitonDegree(fountainGenerator(sessionId, sequence)(), fragmentCount);
}

/// xorshift32, seeded so that both sides derive the same sequence.
function fountainGenerator(sessionId, sequence) {
    let x = ((sessionId >>> 0) ^ Math.imul(sequence, 0x9e3779b9)) >>> 0;
    if (x === 0) x = 0x9e3779b9;
    return () => {
        x ^= x << 13;
        x ^= x >>> 17;
        x ^= x << 5;
        x >>>= 0;
        return x;
    };
}

/// Ideal soliton distribution: half the mixed frames combine 2 fragments, a sixth 3, and so on.
function solitonDegree(u, fragmentCount) {
    return Math.min(Math.floor((2 ** 32 - 1) / (2 ** 32 - u)) + 1, fragmentCount);
}

function xorInto(target, source) {
    for (let i = 0; i < target.length; i++) target[i] ^= source[i];
}

function readU32(bytes, offset) {
    return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
}

function writeU32(bytes, offset, value) {
    bytes[offset] = (value >>> 24) & 0xff;
    bytes[offset + 1] = (value >>> 16) & 0xff;
    bytes[offset + 2] = (value >>> 8) & 0xff;
    bytes[offset + 3] = value & 0xff;
}

export function randomSessionId() {
    const bytes = new Uint8Array(4);
    globalThis.crypto.getRandomValues(bytes);
    return readU32(bytes, 0);
}

/// Splits a message into fragments and produces the frames, forever.
export class Sender {
    constructor(message, { sessionId = randomSessionId(), fragmentSize = 500 } = {}) {
        if (!(message instanceof Uint8Array)) throw new TypeError("message must be a Uint8Array");
        if (message.length < 1 || message.length > MAX_MESSAGE) throw new RangeError("message length out of range");
        if (!Number.isInteger(fragmentSize) || fragmentSize < 1 || fragmentSize > MAX_FRAGMENT) {
            throw new RangeError("fragment size out of range");
        }
        this.message = message;
        this.sessionId = sessionId >>> 0;
        // A short message is one fragment of its own size: padding would only make the code bigger.
        fragmentSize = Math.min(fragmentSize, message.length);
        this.fragmentSize = fragmentSize;
        this.fragmentCount = Math.ceil(message.length / fragmentSize);
        if (this.fragmentCount > MAX_FRAGMENTS) throw new RangeError("too many fragments: use a larger fragment size");
        this.crc = crc32(message);
        const padded = new Uint8Array(this.fragmentCount * fragmentSize);
        padded.set(message);
        this.fragments = [];
        for (let i = 0; i < this.fragmentCount; i++) {
            this.fragments.push(padded.subarray(i * fragmentSize, (i + 1) * fragmentSize));
        }
    }

    /// The bytes of frame `sequence`.
    frameBytes(sequence) {
        const data = new Uint8Array(this.fragmentSize);
        for (const index of fountainIndexes(this.sessionId, sequence, this.fragmentCount)) {
            xorInto(data, this.fragments[index]);
        }
        const frame = new Uint8Array(FRAME_HEADER + this.fragmentSize);
        frame[0] = FRAME_TYPE;
        writeU32(frame, 1, this.sessionId);
        writeU32(frame, 5, this.message.length);
        frame[9] = this.fragmentSize >> 8;
        frame[10] = this.fragmentSize & 0xff;
        writeU32(frame, 11, this.crc);
        writeU32(frame, 15, sequence >>> 0);
        frame.set(data, FRAME_HEADER);
        return frame;
    }

    /// The text of frame `sequence`, to put in a QR code.
    frame(sequence) {
        return FRAME_PREFIX + base45Encode(this.frameBytes(sequence));
    }
}

/// The fields of a frame text, or null if it is not one.
export function parseFrame(text) {
    if (typeof text !== "string" || !text.startsWith(FRAME_PREFIX)) return null;
    const bytes = base45Decode(text.slice(FRAME_PREFIX.length));
    if (!bytes || bytes.length < FRAME_HEADER || bytes[0] !== FRAME_TYPE) return null;
    const frame = {
        sessionId: readU32(bytes, 1),
        length: readU32(bytes, 5),
        fragmentSize: (bytes[9] << 8) | bytes[10],
        crc: readU32(bytes, 11),
        sequence: readU32(bytes, 15),
        data: bytes.subarray(FRAME_HEADER),
    };
    if (frame.length < 1 || frame.length > MAX_MESSAGE) return null;
    if (frame.fragmentSize < 1 || frame.fragmentSize > MAX_FRAGMENT) return null;
    if (frame.data.length !== frame.fragmentSize) return null;
    frame.fragmentCount = Math.ceil(frame.length / frame.fragmentSize);
    if (frame.fragmentCount > MAX_FRAGMENTS) return null;
    return frame;
}

/// Unknown fragment indexes the kept mixed frames may hold in all, per fragment of the message,
/// as in the phone's receiver: without a budget a hostile screen could declare 65 535 one-byte
/// fragments and show frames mixing tens of thousands of them. An honest transfer stays far below
/// it (frames mix about ln K fragments on average).
export const HELD_INDEXES_PER_FRAGMENT = 16;

/// A mixed frame of more fragments than this is skipped before they are chosen, as in the phone's
/// receiver: choosing them walks all the fragments, at every read of a code a hostile screen can
/// hold still. Under the ideal soliton about 0.1% of mixed frames mix more, and they almost never
/// peel.
export const MAX_MIXED_DEGREE = 1024;

/// Collects frames and recovers the message by peeling: a mixed frame whose other fragments are
/// known yields the missing one, which may in turn resolve earlier mixed frames.
export class Receiver {
    constructor() {
        this.reset();
    }

    reset() {
        this.session = null;
        this.other = { sessionId: null, count: 0 };
    }

    /// Progress of the transfer in progress: fragments known of the total, and the message size.
    get progress() {
        if (!this.session) return null;
        const { known, fragmentCount, length } = this.session;
        return { received: known.size, total: fragmentCount, bytesExpected: length };
    }

    /// Feeds one scanned text. The result's `kind` is "notAFrame", "otherSession", "duplicate",
    /// "progress", "complete" (with `message`) or "invalid" (with `reason`).
    receive(text) {
        const frame = parseFrame(text);
        return frame ? this.feed(frame) : { kind: "notAFrame" };
    }

    feed(frame) {
        if (this.session && this.session.complete) {
            return frame.sessionId === this.session.sessionId
                ? { kind: "complete", message: this.session.message }
                : this.startOrIgnore(frame);
        }
        if (this.session && frame.sessionId !== this.session.sessionId) return this.startOrIgnore(frame);
        this.other = { sessionId: null, count: 0 };
        if (!this.session) this.start(frame);
        const session = this.session;
        if (
            frame.length !== session.length ||
            frame.fragmentSize !== session.fragmentSize ||
            frame.crc !== session.crc
        ) {
            return { kind: "invalid", reason: "header" };
        }
        if (session.seen.has(frame.sequence)) return { kind: "duplicate", ...this.progress };
        if (fountainDegree(session.sessionId, frame.sequence, session.fragmentCount) > MAX_MIXED_DEGREE) {
            return { kind: "duplicate", ...this.progress };
        }
        session.seen.add(frame.sequence);
        this.add(fountainIndexes(session.sessionId, frame.sequence, session.fragmentCount), frame.data);
        if (session.known.size < session.fragmentCount) return { kind: "progress", ...this.progress };
        const message = new Uint8Array(session.length);
        for (let i = 0; i < session.fragmentCount; i++) {
            const fragment = session.known.get(i);
            message.set(
                fragment.subarray(0, Math.min(fragment.length, session.length - i * session.fragmentSize)),
                i * session.fragmentSize,
            );
        }
        if (crc32(message) !== session.crc) {
            this.reset();
            return { kind: "invalid", reason: "crc" };
        }
        session.complete = true;
        session.message = message;
        session.mixed = [];
        session.held = 0;
        return { kind: "complete", message };
    }

    /// A frame from another transfer: three in a row start over with it.
    startOrIgnore(frame) {
        if (this.other.sessionId === frame.sessionId) {
            this.other.count += 1;
        } else {
            this.other = { sessionId: frame.sessionId, count: 1 };
        }
        if (this.other.count < 3) return { kind: "otherSession" };
        this.reset();
        return this.feed(frame);
    }

    start(frame) {
        this.session = {
            sessionId: frame.sessionId,
            length: frame.length,
            fragmentSize: frame.fragmentSize,
            crc: frame.crc,
            fragmentCount: frame.fragmentCount,
            known: new Map(),
            mixed: [],
            held: 0, // unknown fragment indexes across `mixed`
            seen: new Set(),
            complete: false,
            message: null,
        };
    }

    add(indexes, data) {
        const session = this.session;
        const part = { indexes: new Set(indexes), data: new Uint8Array(data) };
        for (const index of part.indexes) {
            if (session.known.has(index)) {
                xorInto(part.data, session.known.get(index));
                part.indexes.delete(index);
            }
        }
        if (part.indexes.size === 0) return;
        if (part.indexes.size > 1) {
            // Bounded: a hostile or very long stream can't grow memory without end. The oldest
            // frames go first, to keep at most 4096 frames and the budget of unknown indexes.
            const cap = Math.max(16, Math.min(4 * session.fragmentCount, 4096));
            const budget = HELD_INDEXES_PER_FRAGMENT * session.fragmentCount;
            while (
                session.mixed.length > 0 &&
                (session.mixed.length >= cap || session.held + part.indexes.size > budget)
            ) {
                session.held -= session.mixed.shift().indexes.size;
            }
            session.mixed.push(part);
            session.held += part.indexes.size;
            return;
        }
        const solved = [[part.indexes.values().next().value, part.data]];
        while (solved.length > 0) {
            const [index, fragment] = solved.pop();
            if (session.known.has(index)) continue;
            session.known.set(index, fragment);
            session.mixed = session.mixed.filter((other) => {
                if (!other.indexes.has(index)) return true;
                xorInto(other.data, fragment);
                other.indexes.delete(index);
                session.held -= 1;
                if (other.indexes.size === 1) {
                    session.held -= 1;
                    solved.push([other.indexes.values().next().value, other.data]);
                    return false;
                }
                return other.indexes.size > 0;
            });
        }
    }
}

// MARK: - Request and response

/// "m/44'/397'/0'/0'/1'" or five numbers (hardened either way) as the 20 bytes the APDUs carry.
export function pathBytes(path) {
    const parts =
        typeof path === "string"
            ? path
                  .trim()
                  .split("/")
                  .filter((part) => part && part !== "m")
                  .map((part) => {
                      const hardened = /['hH]$/.test(part);
                      const index = Number(part.replace(/['hH]$/, ""));
                      if (!Number.isInteger(index) || index < 0 || index >= 2 ** 31) {
                          throw new RangeError(`bad path level: ${part}`);
                      }
                      return hardened ? index + 2 ** 31 : index;
                  })
            : Array.from(path, (index) => (index >= 2 ** 31 ? index : index + 2 ** 31));
    if (parts.length !== 5)
        throw new RangeError("the NEAR Ledger protocol needs exactly 5 path levels, e.g. 44'/397'/0'/0'/1'");
    const bytes = new Uint8Array(20);
    parts.forEach((index, i) => writeU32(bytes, i * 4, index));
    return bytes;
}

export function pathString(bytes) {
    const levels = [];
    for (let i = 0; i < 5; i++) {
        const index = readU32(bytes, i * 4);
        levels.push(index >= 2 ** 31 ? `${index - 2 ** 31}'` : String(index));
    }
    return `m/${levels.join("/")}`;
}

/// The message a transfer carries: instruction, path, payload. `deflated` is the payload as raw
/// DEFLATE, made by the caller (the codec has no compressor); it is sent instead of the payload
/// when it is shorter, with the compressed flag and the payload's length. Never for a public key.
export function encodeRequest({ kind, path, payload = new Uint8Array(0), deflated }) {
    const instruction = INSTRUCTIONS[kind];
    if (instruction === undefined) throw new RangeError(`unknown request kind: ${kind}`);
    if (payload.length > MAX_PAYLOAD) throw new RangeError(`payload of ${payload.length} bytes is over the limit`);
    const compress = kind !== "publicKey" && deflated && payload.length > 0 && deflated.length < payload.length;
    const body = compress ? deflated : payload;
    const message = new Uint8Array(21 + (compress ? 4 : 0) + body.length);
    message[0] = compress ? instruction | COMPRESSED_FLAG : instruction;
    message.set(pathBytes(path), 1);
    if (compress) {
        writeU32(message, 21, payload.length);
        message.set(body, 25);
    } else {
        message.set(body, 21);
    }
    return message;
}

/// `{kind, path, payload}`, or for a compressed message `{kind, path, compressed: true,
/// inflatedLength, deflated}` (see `inflateRequest`); null for anything else.
export function parseRequest(message) {
    if (!(message instanceof Uint8Array) || message.length < 21) return null;
    const compressed = (message[0] & COMPRESSED_FLAG) !== 0;
    const kind = KINDS[message[0] & ~COMPRESSED_FLAG];
    if (!kind) return null;
    const path = pathString(message.subarray(1, 21));
    if (!compressed) return { kind, path, payload: message.subarray(21) };
    if (kind === "publicKey" || message.length < 26) return null;
    const inflatedLength = readU32(message, 21);
    if (inflatedLength < 1 || inflatedLength > MAX_PAYLOAD) return null;
    return { kind, path, compressed: true, inflatedLength, deflated: message.subarray(25) };
}

/// A parsed request with its payload inflated, using `inflate(bytes, expectedLength)` from the
/// caller (zlib in Node, DecompressionStream in a browser). Throws unless the length matches.
export function inflateRequest(parsed, inflate) {
    if (!parsed.compressed) return parsed;
    const payload = inflate(parsed.deflated, parsed.inflatedLength);
    if (!(payload instanceof Uint8Array) || payload.length !== parsed.inflatedLength) {
        throw new RangeError(`the payload inflates to ${payload?.length ?? "?"} bytes, not ${parsed.inflatedLength}`);
    }
    return { kind: parsed.kind, path: parsed.path, payload };
}

export function encodeResponse({ sessionId, status, result = new Uint8Array(0) }) {
    const bytes = new Uint8Array(11 + result.length);
    bytes[0] = RESPONSE_TYPE;
    writeU32(bytes, 1, sessionId >>> 0);
    bytes[5] = status >> 8;
    bytes[6] = status & 0xff;
    bytes.set(result, 7);
    writeU32(bytes, 7 + result.length, crc32(bytes.subarray(0, 7 + result.length)));
    return base32Encode(bytes);
}

/// The response the phone shows, or null if the text is not one (a typo fails the CRC).
export function parseResponse(text) {
    const bytes = base32Decode(text);
    if (!bytes || bytes.length < 11 || bytes[0] !== RESPONSE_TYPE) return null;
    const body = bytes.length - 4;
    if (crc32(bytes.subarray(0, body)) !== readU32(bytes, body)) return null;
    return { sessionId: readU32(bytes, 1), status: (bytes[5] << 8) | bytes[6], result: bytes.subarray(7, body) };
}

export const STATUS_MESSAGES = {
    0x9000: "OK",
    0x6985: "rejected on the phone",
    0xb005: "the phone could not decode the request",
    0xb00b: "bad derivation path",
    0xb00d: "the transaction's key is not the phone's key at that path",
    0x5515: "no key on the phone",
    0x6a80: "invalid data",
    0x6d00: "the phone doesn't know this request",
    0x6601: "the phone is busy with another request",
};

export function statusMessage(status) {
    return STATUS_MESSAGES[status] ?? `status ${status.toString(16).padStart(4, "0").toUpperCase()}`;
}
