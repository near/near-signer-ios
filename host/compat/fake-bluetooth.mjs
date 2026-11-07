// A fake Web Bluetooth whose device is near-signer-sim in --ble-packets mode: every GATT write
// goes to the simulator over TCP (each packet as u16 BE length ‖ packet), and every packet it
// sends back becomes a `characteristicvaluechanged` event, so a host's MTU negotiation, Ledger
// framing, chunking and APDUs run unchanged, with no Bluetooth adapter. One GATT connection is
// one TCP connection, as one Bluetooth session is one link for the simulator.
//
// Used by near-connect-ledger-executor.mjs (the real near-connect Ledger executor) and by
// host/optical/test_ble.mjs (NEAR Signer's own executor transport). No npm dependencies.

import net from "node:net";

const SERVICE = "13d63400-2c97-0004-0000-4c6564676572";
const NOTIFY = "13d63400-2c97-0004-0001-4c6564676572";
const WRITE = "13d63400-2c97-0004-0002-4c6564676572";

/// `{ bluetooth, close, stats }`: `bluetooth` stands in for `navigator.bluetooth`, `close` drops
/// the connection, and `stats` counts what was written: signing APDUs, NEAR APDUs whose P1 asks
/// for the ML-DSA-65 key (bit 0x40), the largest APDU, and the writes with and without a response
/// (fast mode skips most responses).
export function makeFakeBluetooth({ port = 9998, host = "127.0.0.1" } = {}) {
    const listeners = [];
    const deviceListeners = [];
    let socket = null;
    let buffer = Buffer.alloc(0);
    const connected = () => socket !== null;
    const notify = (value) => {
        for (const listener of listeners) listener({ target: { value } });
    };
    const stats = {
        signApdus: 0,
        mlDsa65Apdus: 0,
        maxApdu: 0,
        unacknowledged: 0,
        acknowledged: 0,
        run: 0,
        longestRun: 0,
    };
    const send = (data, acknowledged) => {
        if (!socket) throw new Error("GATT server not connected");
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
            if (bytes[5] === 0x80 && bytes.length > 7 && (bytes[7] & 0x40) !== 0) stats.mlDsa65Apdus++;
            stats.maxApdu = Math.max(stats.maxApdu, length);
        }
        const header = Buffer.alloc(2);
        header.writeUInt16BE(bytes.length);
        socket.write(Buffer.concat([header, bytes]));
    };
    const disconnect = () => {
        if (!socket) return;
        socket.destroy();
        socket = null;
        buffer = Buffer.alloc(0);
        // Chrome fires the event asynchronously.
        setTimeout(() => {
            for (const listener of deviceListeners) listener();
        }, 0);
    };
    const writeChar = {
        uuid: WRITE,
        properties: { write: true, writeWithoutResponse: true },
        writeValueWithoutResponse: async (data) => send(data, false),
        writeValueWithResponse: async (data) => send(data, true),
        writeValue: async (data) => send(data, true),
    };
    const notifyChar = {
        uuid: NOTIFY,
        properties: { notify: true },
        addEventListener: (_name, listener) => listeners.push(listener),
        removeEventListener: (_name, listener) => {
            const index = listeners.indexOf(listener);
            if (index >= 0) listeners.splice(index, 1);
        },
        startNotifications: async () => {},
        stopNotifications: async () => {},
    };
    const service = { uuid: SERVICE, getCharacteristics: async () => [writeChar, notifyChar] };
    const gatt = {
        get connected() {
            return connected();
        },
        connect: async () => {
            if (socket) return gatt;
            const next = net.connect({ host, port });
            await new Promise((resolve, reject) => {
                next.once("connect", resolve);
                next.once("error", reject);
            });
            next.on("data", (chunk) => {
                if (next !== socket) return;
                buffer = Buffer.concat([buffer, chunk]);
                while (buffer.length >= 2) {
                    const length = buffer.readUInt16BE(0);
                    if (buffer.length < 2 + length) break;
                    const packet = new Uint8Array(buffer.subarray(2, 2 + length));
                    buffer = buffer.subarray(2 + length);
                    notify(new DataView(packet.buffer, packet.byteOffset, packet.byteLength));
                }
            });
            next.on("close", () => {
                if (next === socket) disconnect();
            });
            next.on("error", () => {});
            socket = next;
            return gatt;
        },
        disconnect,
        getPrimaryServices: async () => [service],
        getPrimaryService: async (uuid) => {
            if (uuid.toLowerCase() !== SERVICE) throw new Error(`no service ${uuid}`);
            return service;
        },
    };
    const device = {
        name: "NEAR Signer",
        addEventListener: (name, listener) => {
            if (name === "gattserverdisconnected") deviceListeners.push(listener);
        },
        removeEventListener: (name, listener) => {
            const index = deviceListeners.indexOf(listener);
            if (name === "gattserverdisconnected" && index >= 0) deviceListeners.splice(index, 1);
        },
        gatt,
    };
    return {
        bluetooth: {
            requestDevice: async ({ filters }) => {
                if (!filters.some((f) => f.services.includes(SERVICE))) throw new Error("Nano X service not requested");
                return device;
            },
        },
        close: disconnect,
        stats,
    };
}
