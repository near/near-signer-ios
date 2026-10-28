// Borsh encodings of what a wallet signs: Transaction (V0), DelegateAction (NEP-366) and the
// NEP-413 payload, from near-connect's action objects. No dependencies; Node and browsers.

const BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

export function base58Encode(bytes) {
    let value = 0n;
    for (const byte of bytes) value = value * 256n + BigInt(byte);
    let out = "";
    while (value > 0n) {
        out = BASE58[Number(value % 58n)] + out;
        value /= 58n;
    }
    for (const byte of bytes) {
        if (byte !== 0) break;
        out = "1" + out;
    }
    return out;
}

export function base58Decode(text) {
    let value = 0n;
    for (const char of text) {
        const digit = BASE58.indexOf(char);
        if (digit < 0) throw new Error(`not base58: ${text}`);
        value = value * 58n + BigInt(digit);
    }
    const bytes = [];
    while (value > 0n) {
        bytes.unshift(Number(value & 0xffn));
        value >>= 8n;
    }
    for (const char of text) {
        if (char !== "1") break;
        bytes.unshift(0);
    }
    return Uint8Array.from(bytes);
}

/// "ed25519:…" or "secp256k1:…" as the borsh PublicKey (key type, then the key).
export function publicKeyBytes(text) {
    const [type, encoded] = text.includes(":") ? text.split(":", 2) : ["ed25519", text];
    const key = base58Decode(encoded);
    if (type === "ed25519" && key.length === 32) return concat(Uint8Array.of(0), key);
    if (type === "secp256k1" && key.length === 64) return concat(Uint8Array.of(1), key);
    throw new Error(`bad public key: ${text}`);
}

export function concat(...parts) {
    const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
    let offset = 0;
    for (const part of parts) {
        out.set(part, offset);
        offset += part.length;
    }
    return out;
}

/// Little-endian integers and length-prefixed bytes, as borsh writes them.
class Writer {
    constructor() {
        this.parts = [];
    }

    u8(value) {
        this.parts.push(Uint8Array.of(value));
        return this;
    }

    u32(value) {
        const bytes = new Uint8Array(4);
        new DataView(bytes.buffer).setUint32(0, Number(value), true);
        this.parts.push(bytes);
        return this;
    }

    u64(value) {
        const bytes = new Uint8Array(8);
        new DataView(bytes.buffer).setBigUint64(0, BigInt(value), true);
        this.parts.push(bytes);
        return this;
    }

    u128(value) {
        let big = BigInt(value);
        if (big < 0n || big >= 1n << 128n) throw new RangeError(`u128 out of range: ${value}`);
        const bytes = new Uint8Array(16);
        for (let i = 0; i < 16; i++) {
            bytes[i] = Number(big & 0xffn);
            big >>= 8n;
        }
        this.parts.push(bytes);
        return this;
    }

    bytes(value) {
        this.u32(value.length);
        this.parts.push(value);
        return this;
    }

    string(value) {
        return this.bytes(new TextEncoder().encode(value));
    }

    raw(value) {
        this.parts.push(value);
        return this;
    }

    build() {
        return concat(...this.parts);
    }
}

function argsBytes(args) {
    if (args instanceof Uint8Array) return args;
    if (typeof args === "string") return Uint8Array.from(atob(args), (c) => c.charCodeAt(0));
    if (args && typeof args === "object") return new TextEncoder().encode(JSON.stringify(args));
    return new Uint8Array(0);
}

/// One of near-connect's actions (`{type, params}`, the wallet-selector format) as a borsh Action.
export function actionBytes(action) {
    const w = new Writer();
    const p = action.params ?? {};
    switch (action.type) {
        case "CreateAccount":
            return w.u8(0).build();
        case "DeployContract":
            return w.u8(1).bytes(argsBytes(p.code)).build();
        case "FunctionCall":
            return w
                .u8(2)
                .string(p.methodName)
                .bytes(argsBytes(p.args))
                .u64(p.gas ?? 30_000_000_000_000n)
                .u128(p.deposit ?? 0n)
                .build();
        case "Transfer":
            return w.u8(3).u128(p.deposit).build();
        case "Stake":
            return w.u8(4).u128(p.stake).raw(publicKeyBytes(p.publicKey)).build();
        case "AddKey": {
            w.u8(5)
                .raw(publicKeyBytes(p.publicKey))
                .u64(p.accessKey?.nonce ?? 0n);
            const permission = p.accessKey?.permission;
            if (permission === "FullAccess" || permission === undefined) return w.u8(1).build();
            w.u8(0);
            if (permission.allowance === undefined || permission.allowance === null) {
                w.u8(0);
            } else {
                w.u8(1).u128(permission.allowance);
            }
            w.string(permission.receiverId).u32((permission.methodNames ?? []).length);
            for (const name of permission.methodNames ?? []) w.string(name);
            return w.build();
        }
        case "DeleteKey":
            return w.u8(6).raw(publicKeyBytes(p.publicKey)).build();
        case "DeleteAccount":
            return w.u8(7).string(p.beneficiaryId).build();
        default:
            throw new Error(`unsupported action type: ${action.type}`);
    }
}

function actionsBytes(actions) {
    const w = new Writer().u32(actions.length);
    for (const action of actions) w.raw(actionBytes(action));
    return w.build();
}

/// borsh(Transaction), what `sign-tx` (APDU `80 02`) signs. `blockHash` is 32 bytes or base58.
export function buildTransaction({ signerId, publicKey, nonce, receiverId, blockHash, actions }) {
    const hash = typeof blockHash === "string" ? base58Decode(blockHash) : blockHash;
    if (hash.length !== 32) throw new Error("block hash must be 32 bytes");
    return new Writer()
        .string(signerId)
        .raw(publicKeyBytes(publicKey))
        .u64(nonce)
        .string(receiverId)
        .raw(hash)
        .raw(actionsBytes(actions))
        .build();
}

/// borsh(DelegateAction), what `sign-delegate` (APDU `80 08`) signs.
export function buildDelegateAction({ senderId, receiverId, actions, nonce, maxBlockHeight, publicKey }) {
    return new Writer()
        .string(senderId)
        .string(receiverId)
        .raw(actionsBytes(actions))
        .u64(nonce)
        .u64(maxBlockHeight)
        .raw(publicKeyBytes(publicKey))
        .build();
}

/// borsh(Payload) of NEP-413, what `sign-message` (APDU `80 07`) signs. `nonce` is 32 bytes.
export function nep413Payload({ message, recipient, nonce, callbackUrl }) {
    if (!(nonce instanceof Uint8Array) || nonce.length !== 32) throw new Error("NEP-413 nonce must be 32 bytes");
    const w = new Writer()
        .string(message)
        .raw(nonce)
        .string(recipient ?? "");
    if (callbackUrl) {
        w.u8(1).string(callbackUrl);
    } else {
        w.u8(0);
    }
    return w.build();
}

/// A signed transaction or delegate action: the bytes, then the ed25519 signature.
export function withSignature(bytes, signature) {
    if (signature.length !== 64) throw new Error("signature must be 64 bytes");
    return concat(bytes, Uint8Array.of(0), signature);
}

function readU32LE(bytes, offset) {
    return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

/// The ed25519 key a borsh Transaction names (after the signer id), or null for another key type.
export function transactionPublicKey(tx) {
    const offset = 4 + readU32LE(tx, 0);
    if (tx.length < offset + 33 || tx[offset] !== 0) return null;
    return tx.subarray(offset + 1, offset + 33);
}

/// The ed25519 key a borsh DelegateAction names (its last field), or null for another key type.
export function delegatePublicKey(delegate) {
    if (delegate.length < 33 || delegate[delegate.length - 33] !== 0) return null;
    return delegate.subarray(delegate.length - 32);
}

export const NEP413_PREFIX = Uint8Array.of(0x9d, 0x01, 0x00, 0x80); // (2^31 + 413) little-endian
export const NEP366_PREFIX = Uint8Array.of(0x6e, 0x01, 0x00, 0x40); // (2^30 + 366) little-endian

export function bytesToBase64(bytes) {
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(binary);
}

export function base64ToBytes(text) {
    return Uint8Array.from(atob(text.trim()), (c) => c.charCodeAt(0));
}
