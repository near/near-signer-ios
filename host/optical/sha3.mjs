// SHA3-256 (FIPS 202): Keccak-f[1600] with a rate of 136 bytes and the 0x06…0x80 padding, as
// NEAR hashes ML-DSA-65 keys and universal account state inits. Keccak-256 (0x01 padding) gives
// different digests. No dependencies; Node and browsers. Each 64-bit lane is two 32-bit words,
// low word first, so everything stays in plain integer arithmetic.

/// The 24 round constants, as (low word, high word) pairs.
const ROUND_CONSTANTS = [
    [0x00000001, 0x00000000],
    [0x00008082, 0x00000000],
    [0x0000808a, 0x80000000],
    [0x80008000, 0x80000000],
    [0x0000808b, 0x00000000],
    [0x80000001, 0x00000000],
    [0x80008081, 0x80000000],
    [0x00008009, 0x80000000],
    [0x0000008a, 0x00000000],
    [0x00000088, 0x00000000],
    [0x80008009, 0x00000000],
    [0x8000000a, 0x00000000],
    [0x8000808b, 0x00000000],
    [0x0000008b, 0x80000000],
    [0x00008089, 0x80000000],
    [0x00008003, 0x80000000],
    [0x00008002, 0x80000000],
    [0x00000080, 0x80000000],
    [0x0000800a, 0x00000000],
    [0x8000000a, 0x80000000],
    [0x80008081, 0x80000000],
    [0x00008080, 0x80000000],
    [0x80000001, 0x00000000],
    [0x80008008, 0x80000000],
];

/// The rotation of lane (x, y), indexed by x + 5y.
const ROTATIONS = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14];

/// Where lane (x, y) goes in the pi step, (y, 2x + 3y), indexed by x + 5y.
const DESTINATIONS = ROTATIONS.map((_, i) => {
    const x = i % 5;
    const y = Math.floor(i / 5);
    return y + 5 * ((2 * x + 3 * y) % 5);
});

const RATE = 136;

/// One Keccak-f[1600] permutation of the state: 25 lanes, each the words `state[2i]` (low) and
/// `state[2i + 1]` (high).
function keccakF(state) {
    const column = new Uint32Array(10);
    const shift = new Uint32Array(10);
    const moved = new Uint32Array(50);
    for (let round = 0; round < 24; round++) {
        // Theta: every lane absorbs the parity of two columns.
        for (let x = 0; x < 5; x++) {
            column[2 * x] =
                state[2 * x] ^ state[2 * (x + 5)] ^ state[2 * (x + 10)] ^ state[2 * (x + 15)] ^ state[2 * (x + 20)];
            column[2 * x + 1] =
                state[2 * x + 1] ^
                state[2 * (x + 5) + 1] ^
                state[2 * (x + 10) + 1] ^
                state[2 * (x + 15) + 1] ^
                state[2 * (x + 20) + 1];
        }
        for (let x = 0; x < 5; x++) {
            const left = 2 * ((x + 4) % 5);
            const right = 2 * ((x + 1) % 5);
            const lo = column[right];
            const hi = column[right + 1];
            shift[2 * x] = column[left] ^ ((lo << 1) | (hi >>> 31));
            shift[2 * x + 1] = column[left + 1] ^ ((hi << 1) | (lo >>> 31));
        }
        for (let i = 0; i < 25; i++) {
            state[2 * i] ^= shift[2 * (i % 5)];
            state[2 * i + 1] ^= shift[2 * (i % 5) + 1];
        }
        // Rho and pi: each lane is rotated and moved.
        for (let i = 0; i < 25; i++) {
            const r = ROTATIONS[i];
            const lo = state[2 * i];
            const hi = state[2 * i + 1];
            const j = 2 * DESTINATIONS[i];
            if (r === 0) {
                moved[j] = lo;
                moved[j + 1] = hi;
            } else if (r < 32) {
                moved[j] = (lo << r) | (hi >>> (32 - r));
                moved[j + 1] = (hi << r) | (lo >>> (32 - r));
            } else if (r === 32) {
                moved[j] = hi;
                moved[j + 1] = lo;
            } else {
                moved[j] = (hi << (r - 32)) | (lo >>> (64 - r));
                moved[j + 1] = (lo << (r - 32)) | (hi >>> (64 - r));
            }
        }
        // Chi: each lane is mixed with the two to its right in the row.
        for (let y = 0; y < 5; y++) {
            for (let x = 0; x < 5; x++) {
                const i = 2 * (x + 5 * y);
                const next = 2 * (((x + 1) % 5) + 5 * y);
                const after = 2 * (((x + 2) % 5) + 5 * y);
                state[i] = moved[i] ^ (~moved[next] & moved[after]);
                state[i + 1] = moved[i + 1] ^ (~moved[next + 1] & moved[after + 1]);
            }
        }
        // Iota: the round constant.
        state[0] ^= ROUND_CONSTANTS[round][0];
        state[1] ^= ROUND_CONSTANTS[round][1];
    }
}

/// SHA3-256 of `bytes`, 32 bytes.
export function sha3_256(bytes) {
    if (!(bytes instanceof Uint8Array)) throw new TypeError("sha3_256 takes a Uint8Array");
    const state = new Uint32Array(50);
    // The message, then the padding: 0x06, zeros, and 0x80 on the last byte of the block (one
    // byte of 0x86 when a single byte is left).
    const blocks = Math.floor(bytes.length / RATE) + 1;
    const padded = new Uint8Array(blocks * RATE);
    padded.set(bytes);
    padded[bytes.length] ^= 0x06;
    padded[padded.length - 1] ^= 0x80;
    const view = new DataView(padded.buffer);
    for (let block = 0; block < blocks; block++) {
        const offset = block * RATE;
        for (let word = 0; word < RATE / 4; word++) {
            state[word] ^= view.getUint32(offset + 4 * word, true);
        }
        keccakF(state);
    }
    const digest = new Uint8Array(32);
    const out = new DataView(digest.buffer);
    for (let word = 0; word < 8; word++) out.setUint32(4 * word, state[word], true);
    return digest;
}
