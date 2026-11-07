// Unit tests for the camera transfer codec: `node --test host/optical/`.
import assert from "node:assert/strict";
import { test } from "node:test";
import zlib from "node:zlib";
import {
    COMPRESSED_FLAG,
    HELD_INDEXES_PER_FRAGMENT,
    MAX_MIXED_DEGREE,
    Receiver,
    Sender,
    base32Decode,
    base32Encode,
    base45Decode,
    base45Encode,
    crc32,
    encodeRequest,
    encodeResponse,
    fountainDegree,
    fountainIndexes,
    grouped,
    inflateRequest,
    parseFrame,
    parseRequest,
    parseResponse,
    pathBytes,
    statusMessage,
} from "./optical.mjs";
import {
    actionBytes,
    base58Encode,
    base64ToBytes,
    buildDelegateAction,
    buildTransaction,
    nep413Nonce,
    nep413Payload,
    withSignature,
} from "./borsh.mjs";
import { qrMatrix, renderTerminal } from "./qr.mjs";

const utf8 = (text) => new TextEncoder().encode(text);

function randomBytes(count, seed = 7) {
    const out = new Uint8Array(count);
    let x = seed;
    for (let i = 0; i < count; i++) {
        x = (Math.imul(x, 1103515245) + 12345) >>> 0;
        out[i] = x >>> 24;
    }
    return out;
}

test("base45 matches RFC 9285", () => {
    assert.equal(base45Encode(utf8("AB")), "BB8");
    assert.equal(base45Encode(utf8("Hello!!")), "%69 VD92EX0");
    assert.equal(base45Encode(utf8("base-45")), "UJCLQE7W581");
    assert.deepEqual(base45Decode("QED8WEX0"), utf8("ietf!"));
    assert.deepEqual(base45Decode(base45Encode(randomBytes(1001))), randomBytes(1001));
    assert.equal(base45Decode("A"), null, "a lone character");
    assert.equal(base45Decode("GGW"), null, "above 65535");
    assert.equal(base45Decode("ab8"), null, "lower case is not in the alphabet");
});

test("Crockford base32 is lenient on input", () => {
    const bytes = randomBytes(75);
    const text = base32Encode(bytes);
    assert.match(text, /^[0-9A-HJKMNP-TV-Z]+$/);
    assert.deepEqual(base32Decode(text), bytes);
    assert.deepEqual(base32Decode(grouped(text).toLowerCase()), bytes);
    assert.deepEqual(
        base32Decode(
            text
                .replaceAll("1", "l")
                .replaceAll("0", "O")
                .replaceAll(/(.{4})/g, "$1-"),
        ),
        bytes,
    );
    assert.equal(base32Decode("U"), null);
    assert.deepEqual(base32Decode(base32Encode(utf8("x"))), utf8("x"));
});

test("crc32 is the IEEE one", () => {
    assert.equal(crc32(utf8("123456789")), 0xcbf43926);
    assert.equal(crc32(new Uint8Array(0)), 0);
});

test("fountainIndexes is deterministic and within bounds", () => {
    assert.deepEqual(fountainIndexes(0x12345678, 3, 7), [3]);
    assert.deepEqual(fountainIndexes(0x12345678, 17, 7), [3], "even blocks repeat the fragments");
    assert.deepEqual(fountainIndexes(7, 538, 4), [2]);
    assert.ok(fountainIndexes(0x12345678, 10, 7).length > 1, "odd blocks mix");
    assert.deepEqual(fountainIndexes(0x12345678, 10, 7), [1, 2]);
    assert.deepEqual(fountainIndexes(1, 1000, 300), [130, 181, 258]);
    assert.deepEqual(fountainIndexes(0x12345678, 10, 7), fountainIndexes(0x12345678, 10, 7));
    for (let s = 7; s < 2000; s++) {
        const indexes = fountainIndexes(0x12345678, s, 7);
        assert.ok(indexes.length >= 1 && indexes.length <= 7);
        assert.equal(new Set(indexes).size, indexes.length, "distinct");
        assert.ok(indexes.every((i) => i >= 0 && i < 7));
    }
    // A zero seed is replaced, and the session id matters.
    assert.ok(fountainIndexes(0, 0, 1).length === 1);
    assert.notDeepEqual(
        Array.from({ length: 50 }, (_, s) => fountainIndexes(1, 300 + s, 300)),
        Array.from({ length: 50 }, (_, s) => fountainIndexes(2, 300 + s, 300)),
    );
});

test("borsh builders reproduce near-api-js bytes", () => {
    // The transfer host/compat uses: alice.testnet -> bob.testnet, built by near-api-js.
    const expected = base64ToBytes(
        "DQAAAGFsaWNlLnRlc3RuZXQAxXHjPi42wsco1hfqd6iOIyDIaX6si0Y638ASi5aCXL8HAAAAAAAAAAsAAABib2IudGVzdG5ldDlKvrNecHYJ3o9ztj1DvRo3b/5nk1yqaJN90pvATmc8AQAAAAMAAIBxZDO2KaM9AQAAAAAA",
    );
    const publicKey = `ed25519:${base58Encode(expected.subarray(18, 50))}`;
    const blockHash = expected.subarray(73, 105);
    let deposit = 0n;
    for (let i = 15; i >= 0; i--) deposit = (deposit << 8n) | BigInt(expected[110 + i]);
    const built = buildTransaction({
        signerId: "alice.testnet",
        publicKey,
        nonce: 7,
        receiverId: "bob.testnet",
        blockHash,
        actions: [{ type: "Transfer", params: { deposit } }],
    });
    assert.deepEqual(built, expected);
    assert.equal(deposit, 1_500_000_000_000_000_000_000_000n);

    const call = actionBytes({
        type: "FunctionCall",
        params: {
            methodName: "ft_transfer",
            args: { receiver_id: "bob.near", amount: "1" },
            gas: "30000000000000",
            deposit: "1",
        },
    });
    assert.equal(call[0], 2);
    assert.equal(new TextDecoder().decode(call.subarray(5, 16)), "ft_transfer");
    const addKey = actionBytes({
        type: "AddKey",
        params: {
            publicKey,
            accessKey: {
                permission: { receiverId: "app.near", methodNames: ["a", "bc"], allowance: "250000000000000000000000" },
            },
        },
    });
    assert.deepEqual(Array.from(addKey.subarray(0, 1)), [5]);
    assert.deepEqual(
        Array.from(addKey.subarray(34, 44)),
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        "nonce 0, FunctionCall permission, Some(allowance)",
    );
    assert.deepEqual(
        Array.from(
            actionBytes({ type: "AddKey", params: { publicKey, accessKey: { permission: "FullAccess" } } }).subarray(
                42,
            ),
        ),
        [1],
    );

    const payload = nep413Payload({ message: "hi", recipient: "app.near", nonce: new Uint8Array(32) });
    assert.equal(payload.length, 4 + 2 + 32 + 4 + 8 + 1);
    assert.equal(payload[payload.length - 1], 0);
    const delegate = buildDelegateAction({
        senderId: "alice.near",
        receiverId: "bob.near",
        actions: [{ type: "Transfer", params: { deposit: "1" } }],
        nonce: 1,
        maxBlockHeight: 100,
        publicKey,
    });
    assert.equal(delegate.length, 14 + 12 + 4 + 17 + 8 + 8 + 33);
    assert.equal(withSignature(delegate, new Uint8Array(64)).length, delegate.length + 65);
});

test("borsh builders refuse what they would otherwise fill in", () => {
    const publicKey = "ed25519:EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz";
    // An AddKey without a permission is not a full-access key.
    assert.throws(() => actionBytes({ type: "AddKey", params: { publicKey } }), /AddKey needs a permission/);
    assert.throws(
        () => actionBytes({ type: "AddKey", params: { publicKey, accessKey: {} } }),
        /AddKey needs a permission/,
    );
    assert.throws(
        () => actionBytes({ type: "AddKey", params: { publicKey, accessKey: { permission: { methodNames: [] } } } }),
        /AddKey needs a permission/,
        "a function-call permission names its contract",
    );
    // Contract code is bytes, not missing and not an object turned into JSON.
    assert.throws(() => actionBytes({ type: "DeployContract", params: {} }), /contract code as bytes/);
    assert.throws(() => actionBytes({ type: "DeployContract", params: { code: { 0: 1 } } }), /contract code as bytes/);
    assert.equal(actionBytes({ type: "DeployContract", params: { code: new Uint8Array([1, 2]).buffer } }).length, 7);
    // A missing string is not an empty one.
    assert.throws(() => actionBytes({ type: "FunctionCall", params: { args: {}, gas: "1", deposit: "0" } }), /string/);
    assert.throws(() => actionBytes({ type: "DeleteAccount", params: {} }), /string/);
    // NEP-413: the nonce is the app's 32 bytes, never zeros filled in; the recipient is required.
    const nonce = randomBytes(32);
    assert.deepEqual(nep413Nonce(nonce), nonce);
    assert.deepEqual(nep413Nonce(Array.from(nonce)), nonce, "a Uint8Array that went through JSON");
    assert.deepEqual(nep413Nonce(nonce.buffer), nonce);
    for (const bad of [undefined, null, "", new Uint8Array(31), new Uint8Array(33), [256, ...new Array(31).fill(0)]]) {
        assert.throws(() => nep413Nonce(bad), /no 32-byte nonce/);
    }
    assert.throws(() => nep413Payload({ message: "hi", nonce }), /names no recipient/);
    assert.throws(() => nep413Payload({ message: "hi", recipient: "", nonce }), /names no recipient/);
    assert.throws(() => nep413Payload({ recipient: "app.near", nonce }), /message is missing/);
});

test("frames round-trip through parseFrame", () => {
    const sender = new Sender(utf8("hello"), { sessionId: 0x01020304, fragmentSize: 4 });
    assert.equal(sender.fragmentCount, 2);
    const frame = parseFrame(sender.frame(1));
    assert.equal(frame.sessionId, 0x01020304);
    assert.equal(frame.length, 5);
    assert.equal(frame.fragmentSize, 4);
    assert.equal(frame.sequence, 1);
    assert.deepEqual(frame.data, Uint8Array.of(111, 0, 0, 0));
    assert.equal(parseFrame("hello"), null);
    assert.equal(parseFrame("NS1:BB8"), null);
    assert.equal(parseFrame(sender.frame(0).slice(0, -3)), null, "a short frame");
    // A short message is one fragment of its own size.
    assert.equal(new Sender(utf8("hi"), { fragmentSize: 500 }).fragmentSize, 2);
});

test("receiver recovers a message in order", () => {
    const message = randomBytes(2000);
    const sender = new Sender(message, { sessionId: 42, fragmentSize: 100 });
    const receiver = new Receiver();
    let result;
    for (let s = 0; s < sender.fragmentCount; s++) {
        result = receiver.receive(sender.frame(s));
        if (s + 1 < sender.fragmentCount) assert.equal(result.kind, "progress");
    }
    assert.equal(result.kind, "complete");
    assert.deepEqual(result.message, message);
    assert.equal(receiver.receive(sender.frame(0)).kind, "complete", "stays complete");
});

test("receiver recovers a message from a lossy stream started midway", () => {
    const message = randomBytes(30000);
    const sender = new Sender(message, { sessionId: 0xdeadbeef, fragmentSize: 300 });
    const receiver = new Receiver();
    let x = 99;
    let frames = 0;
    for (let s = 57; ; s++) {
        x = (Math.imul(x, 1103515245) + 12345) >>> 0;
        if (x / 2 ** 32 < 0.4) continue;
        frames += 1;
        const result = receiver.receive(sender.frame(s));
        assert.notEqual(result.kind, "invalid");
        if (result.kind === "complete") {
            assert.deepEqual(result.message, message);
            break;
        }
        assert.ok(frames < 5000, "did not complete");
    }
    // Even blocks replay the fragments, so losses cost a little more than in a pure fountain.
    assert.ok(frames < sender.fragmentCount * 3, `took ${frames} frames for ${sender.fragmentCount} fragments`);
});

test("receiver handles one fragment and a large message", () => {
    const one = new Sender(utf8("x"), { fragmentSize: 50 });
    assert.equal(new Receiver().receive(one.frame(5)).kind, "complete", "a mixed frame of a single fragment");
    const message = randomBytes(300 * 1024);
    const sender = new Sender(message, { fragmentSize: 500 });
    const receiver = new Receiver();
    let result;
    for (let s = 0; s < sender.fragmentCount; s++) result = receiver.receive(sender.frame(s));
    assert.equal(result.kind, "complete");
    assert.deepEqual(result.message, message);
});

test("receiver skips frames that mix more than 1024 fragments", () => {
    // A hostile screen declares 65 535 one-byte fragments and holds up codes that mix thousands of
    // them: they are skipped before their fragments are chosen, and narrow frames are still kept.
    const count = 65535;
    const sender = new Sender(new Uint8Array(count).fill(0x5a), { sessionId: 77, fragmentSize: 1 });
    const receiver = new Receiver();
    let wide = 0;
    for (let s = count; wide < 20; s++) {
        const degree = fountainDegree(77, s, count);
        if (degree <= MAX_MIXED_DEGREE) continue;
        if (wide < 3) assert.equal(fountainIndexes(77, s, count).length, degree);
        assert.equal(receiver.receive(sender.frame(s)).kind, "duplicate");
        wide += 1;
    }
    assert.equal(receiver.session.held, 0);
    for (let s = count; ; s++) {
        if (fountainDegree(77, s, count) !== 3) continue;
        receiver.receive(sender.frame(s));
        break;
    }
    assert.equal(receiver.session.held, 3, "a frame of a few fragments is kept");
});

test("receiver holds a bounded number of unknown fragment indexes", () => {
    // Frames of up to 1024 fragments are kept while they fit, 16 indexes per fragment in all; past
    // the budget the oldest go, here until twice the budget has been shown.
    const heldOf = (receiver) => receiver.session.mixed.reduce((n, part) => n + part.indexes.size, 0);
    const small = 2000;
    const bounded = new Sender(new Uint8Array(small).fill(0x5a), { sessionId: 78, fragmentSize: 1 });
    const other = new Receiver();
    let shown = 0;
    for (let s = small; shown <= 2 * HELD_INDEXES_PER_FRAGMENT * small; s++) {
        const degree = fountainDegree(78, s, small);
        if (degree <= 200 || degree > MAX_MIXED_DEGREE) continue;
        other.receive(bounded.frame(s));
        shown += degree;
        assert.ok(other.session.held <= HELD_INDEXES_PER_FRAGMENT * small, `holds ${other.session.held}`);
        assert.equal(other.session.held, heldOf(other));
    }
    assert.ok(other.session.held > HELD_INDEXES_PER_FRAGMENT * small - MAX_MIXED_DEGREE, "kept while they fit");
});

test("receiver bounds the mixed frames it keeps", () => {
    // Fragments 0 and 1 never arrive directly, only mixed frames: many more than are kept.
    const message = randomBytes(4000);
    const sender = new Sender(message, { sessionId: 31, fragmentSize: 1000 });
    const receiver = new Receiver();
    receiver.receive(sender.frame(2));
    receiver.receive(sender.frame(3));
    let result;
    for (let s = 4; s < 5000; s++) {
        if (s % 4 < 2 && Math.floor(s / 4) % 2 === 0) continue; // fragments 0 and 1 in even blocks
        result = receiver.receive(sender.frame(s));
        assert.ok(receiver.session.mixed.length <= 16, "at most max(16, min(4K, 4096)) kept");
        if (result.kind === "complete") break;
    }
    assert.equal(result.kind, "complete");
    assert.deepEqual(result.message, message);
});

test("receiver rejects a corrupted message and ignores strays", () => {
    const sender = new Sender(randomBytes(300), { sessionId: 5, fragmentSize: 100 });
    const receiver = new Receiver();
    receiver.receive(sender.frame(0));
    receiver.receive(sender.frame(1));
    const bytes = sender.frameBytes(2);
    bytes[bytes.length - 1] ^= 0xff;
    const { base45Encode: encode } = { base45Encode };
    const result = receiver.receive("NS1:" + encode(bytes));
    assert.equal(result.kind, "invalid");
    assert.equal(result.reason, "crc");
    assert.equal(receiver.progress, null, "starts over");
    // Another transfer's frames are ignored until three arrive in a row.
    receiver.receive(sender.frame(0));
    const other = new Sender(randomBytes(50), { sessionId: 6, fragmentSize: 25 });
    assert.equal(receiver.receive(other.frame(0)).kind, "otherSession");
    assert.equal(receiver.receive(sender.frame(1)).kind, "progress");
    assert.equal(receiver.receive(other.frame(0)).kind, "otherSession");
    assert.equal(receiver.receive(other.frame(0)).kind, "otherSession");
    assert.equal(receiver.receive(other.frame(1)).kind, "progress", "the third starts over with the new transfer");
    assert.equal(receiver.progress.total, 2);
    assert.equal(receiver.receive(other.frame(1)).kind, "duplicate");
    assert.equal(receiver.receive("not a code").kind, "notAFrame");
});

test("requests and responses round-trip", () => {
    const request = encodeRequest({ kind: "transaction", path: "m/44'/397'/0'/0'/1'", payload: utf8("tx") });
    assert.equal(request[0], 0x02);
    assert.deepEqual(
        Array.from(request.subarray(1, 21)),
        [0x80, 0, 0, 44, 0x80, 0, 1, 141, 0x80, 0, 0, 0, 0x80, 0, 0, 0, 0x80, 0, 0, 1],
    );
    assert.deepEqual(parseRequest(request), { kind: "transaction", path: "m/44'/397'/0'/0'/1'", payload: utf8("tx") });
    assert.deepEqual(pathBytes([44, 397, 0, 0, 1]), request.subarray(1, 21));
    assert.deepEqual(pathBytes("44'/397'/0'/0'/1'"), request.subarray(1, 21));
    assert.throws(() => pathBytes("m/44'/397'/0'"));
    assert.equal(encodeRequest({ kind: "publicKey", path: [44, 397, 0, 0, 1] }).length, 21);
    assert.equal(parseRequest(new Uint8Array(20)), null);

    const signature = randomBytes(64);
    const text = encodeResponse({ sessionId: 0x01020304, status: 0x9000, result: signature });
    assert.match(text, /^[0-9A-HJKMNP-TV-Z]+$/);
    assert.deepEqual(parseResponse(text), { sessionId: 0x01020304, status: 0x9000, result: signature });
    assert.deepEqual(parseResponse(grouped(text).toLowerCase()), {
        sessionId: 0x01020304,
        status: 0x9000,
        result: signature,
    });
    assert.equal(parseResponse(text.slice(0, -1) + (text.endsWith("A") ? "B" : "A")), null, "a typo fails the CRC");
    assert.equal(parseResponse(encodeResponse({ sessionId: 1, status: 0xb005 })).status, 0xb005);
    assert.equal(parseResponse(encodeResponse({ sessionId: 1, status: 0xb005 })).result.length, 0);
    // A message that isn't a request gets a status of its own, which the executor shows.
    for (const [status, words] of [
        [0x6d00, "doesn't know this request"],
        [0xb00b, "bad derivation path"],
        [0x6a80, "invalid data"],
    ]) {
        assert.equal(parseResponse(encodeResponse({ sessionId: 2, status })).status, status);
        assert.match(statusMessage(status), new RegExp(words));
    }
    assert.equal(statusMessage(0x1234), "status 1234");
});

test("compressed payloads: flag, length, inflate, and never for a public key", () => {
    const path = "m/44'/397'/0'/0'/1'";
    const payload = new Uint8Array(20000);
    for (let i = 0; i < payload.length; i++) payload[i] = (i * 7) % 251;
    const deflated = new Uint8Array(zlib.deflateRawSync(payload, { level: 9 }));
    assert.ok(deflated.length < payload.length / 4, "the sample compresses well");
    const inflate = (bytes, expected) => new Uint8Array(zlib.inflateRawSync(bytes, { maxOutputLength: expected }));

    const message = encodeRequest({ kind: "transaction", path, payload, deflated });
    assert.equal(message[0], 0x02 | COMPRESSED_FLAG);
    assert.equal(message.length, 25 + deflated.length);
    assert.deepEqual(Array.from(message.subarray(21, 25)), [0, 0, 0x4e, 0x20], "payload length, big-endian");
    const parsed = parseRequest(message);
    assert.equal(parsed.compressed, true);
    assert.equal(parsed.inflatedLength, 20000);
    assert.deepEqual(inflateRequest(parsed, inflate), { kind: "transaction", path, payload });
    // Plain when compression doesn't pay, or for a public key.
    const plain = encodeRequest({ kind: "transaction", path, payload, deflated: new Uint8Array(payload.length + 1) });
    assert.equal(plain[0], 0x02);
    assert.equal(plain.length, 21 + payload.length);
    assert.deepEqual(inflateRequest(parseRequest(plain), inflate), { kind: "transaction", path, payload });
    assert.equal(encodeRequest({ kind: "publicKey", path, deflated: new Uint8Array(0) }).length, 21);
    // A bad length field, a lying length, or a flag on a public key is refused.
    const zeroLength = Uint8Array.from(message);
    zeroLength.set([0, 0, 0, 0], 21);
    assert.equal(parseRequest(zeroLength), null);
    const tooLong = Uint8Array.from(message);
    tooLong.set([0, 0x18, 0x6a, 0x01], 21); // 1 600 001
    assert.equal(parseRequest(tooLong), null);
    const lying = Uint8Array.from(message);
    lying.set([0, 0, 0x4e, 0x21], 21);
    assert.throws(() => inflateRequest(parseRequest(lying), inflate), /inflates to/);
    const keyFlag = encodeRequest({ kind: "publicKey", path });
    keyFlag[0] |= COMPRESSED_FLAG;
    assert.equal(parseRequest(keyFlag), null);
    assert.equal(parseRequest(message.subarray(0, 25)), null, "no compressed bytes");

    // Through the frames: what the phone does.
    const sender = new Sender(message, { sessionId: 0xc0ffee, fragmentSize: 500 });
    const receiver = new Receiver();
    let outcome;
    for (let s = 3; ; s++) {
        outcome = receiver.receive(sender.frame(s));
        if (outcome.kind === "complete") break;
    }
    assert.deepEqual(inflateRequest(parseRequest(outcome.message), inflate).payload, payload);
});

test("codes use the alphanumeric mode and render for a terminal", () => {
    const sender = new Sender(randomBytes(1000), { fragmentSize: 220 });
    const matrix = qrMatrix(sender.frame(0));
    assert.equal(matrix.size, 57, "version 10 holds a 220-byte fragment");
    const lines = renderTerminal(matrix);
    assert.equal(lines.length, (57 + 4) / 2 + 0.5);
    assert.ok(lines.every((line) => line.length === 61));
    assert.ok(qrMatrix(encodeResponse({ sessionId: 1, status: 0x9000, result: randomBytes(64) })).size <= 41);
});
