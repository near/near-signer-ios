// See lib.mjs for how to run these. The executor's Bluetooth transport in the dapp: a fake
// navigator.bluetooth in every document of the page (near-connect's sandboxed iframe included)
// hands each GATT write to this script, which forwards it to near-signer-sim --ble-packets over
// TCP and returns the simulator's reply packets for the fake to deliver as notifications. So the
// executor's own screens, framing, chunking and APDUs run in the browser against the simulator,
// the way they would against the phone, with no Bluetooth adapter. The simulator is started here.
//
// Connect with the classic key: the request screen offers "Use Bluetooth instead", the Bluetooth
// screen connects on a click and the account list follows; the choice is remembered, so the next
// request (a message to sign) starts over Bluetooth; a cancelled device chooser is said on the
// screen with the button back; "Use the camera instead" brings the codes up again. Then the
// quantum-safe key over Bluetooth: P1's bit 0x40 on every APDU, the key's universal account in
// the list, and a message signed with ML-DSA-65 (the flag follows the connected account's key).
// Nothing is sent to testnet.
import { execFileSync, spawn } from "node:child_process";
import net from "node:net";
import { SIM, launch, shot } from "./lib.mjs";
import { accountIdForPublicKey } from "../borsh.mjs";

const PORT = 9995;

function check(condition, message) {
    if (!condition) throw new Error(`FAILED: ${message}`);
}

// MARK: - The simulator, and the links to it

const sim = spawn(SIM, ["--ble-packets", "--port", String(PORT), "--auto-approve"], {
    stdio: ["ignore", "pipe", "pipe"],
});
await new Promise((resolve, reject) => {
    let output = "";
    sim.stdout.on("data", (chunk) => {
        output += chunk;
        if (/listening on/.test(output)) resolve();
    });
    sim.on("exit", (code) => reject(new Error(`near-signer-sim exited with ${code}: ${output}`)));
});
process.on("exit", () => sim.kill());

/// One GATT connection, as one TCP connection to the simulator. `write` sends a packet and, when
/// it completes a message (the Ledger framing says so), resolves with the packets of the
/// simulator's whole answer; with an empty list otherwise. The MTU probe gets its one packet.
function openLink() {
    const socket = net.connect({ host: "127.0.0.1", port: PORT });
    let buffer = Buffer.alloc(0);
    const queue = [];
    let waiting = null;
    socket.on("data", (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        while (buffer.length >= 2) {
            const length = buffer.readUInt16BE(0);
            if (buffer.length < 2 + length) break;
            queue.push(Array.from(buffer.subarray(2, 2 + length)));
            buffer = buffer.subarray(2 + length);
            if (waiting) {
                const resolve = waiting;
                waiting = null;
                resolve();
            }
        }
    });
    const nextPacket = async () => {
        while (queue.length === 0) await new Promise((resolve) => (waiting = resolve));
        return queue.shift();
    };
    let remaining = 0; // bytes of the message being written that are still to come
    const write = async (bytes) => {
        const header = Buffer.alloc(2);
        header.writeUInt16BE(bytes.length);
        socket.write(Buffer.concat([header, Buffer.from(bytes)]));
        if (bytes[0] === 0x08) return [await nextPacket()];
        const seq = (bytes[1] << 8) | bytes[2];
        if (seq === 0) remaining = ((bytes[3] << 8) | bytes[4]) - (bytes.length - 5);
        else remaining -= bytes.length - 3;
        if (remaining > 0) return [];
        // The answer, however many packets: the first says how long it is.
        const packets = [];
        let expected = -1;
        let got = 0;
        while (expected < 0 || got < expected) {
            const packet = await nextPacket();
            packets.push(packet);
            if (packet[0] !== 0x05) continue;
            if (expected < 0) {
                expected = (packet[3] << 8) | packet[4];
                got += packet.length - 5;
            } else {
                got += packet.length - 3;
            }
        }
        return packets;
    };
    return { write, close: () => socket.destroy() };
}

const links = new Map();
let nextLinkId = 1;
const stats = { connects: 0, writes: 0, signApdus: 0, mlDsa65Apdus: 0 };

/// The fake, as every document of the page gets it: a Nano X whose GATT server is the simulator.
/// `window.__bleCancelNext` makes the next device chooser throw as a cancelled one does.
const FAKE_BLUETOOTH = `(() => {
    const SERVICE = "13d63400-2c97-0004-0000-4c6564676572";
    const makeDevice = () => {
        let id = null;
        const listeners = [];
        const deviceListeners = [];
        const deliver = (packets) => {
            for (const packet of packets) {
                const bytes = Uint8Array.from(packet);
                const value = new DataView(bytes.buffer);
                for (const listener of listeners) listener({ target: { value } });
            }
        };
        const write = async (data) => {
            const view = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
            const reply = await window.__bleWrite(id, Array.from(view));
            setTimeout(() => deliver(reply), 0);
        };
        const writeChar = {
            uuid: "13d63400-2c97-0004-0002-4c6564676572",
            properties: { write: true, writeWithoutResponse: false },
            writeValueWithResponse: write,
            writeValue: write,
        };
        const notifyChar = {
            uuid: "13d63400-2c97-0004-0001-4c6564676572",
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
            get connected() { return id !== null; },
            connect: async () => {
                if (id === null) id = await window.__bleConnect();
                return gatt;
            },
            disconnect: () => {
                if (id === null) return;
                const old = id;
                id = null;
                window.__bleDisconnect(old);
                setTimeout(() => { for (const listener of deviceListeners) listener(); }, 0);
            },
            getPrimaryService: async () => service,
            getPrimaryServices: async () => [service],
        };
        return {
            name: "NEAR Signer",
            gatt,
            addEventListener: (name, listener) => { if (name === "gattserverdisconnected") deviceListeners.push(listener); },
            removeEventListener: () => {},
        };
    };
    const bluetooth = {
        requestDevice: async ({ filters }) => {
            if (window.__bleCancelNext) {
                window.__bleCancelNext = false;
                throw new DOMException("User cancelled the requestDevice() chooser.", "NotFoundError");
            }
            if (!filters?.some((f) => f.services?.includes(SERVICE))) throw new DOMException("no Nano X service asked for", "NotFoundError");
            return makeDevice();
        },
    };
    Object.defineProperty(navigator, "bluetooth", { value: bluetooth, configurable: true });
})();`;

// MARK: - The dapp

const { browser, page, logs } = await launch({ width: 1100, height: 950 });
await page.exposeFunction("__bleConnect", () => {
    const id = nextLinkId++;
    links.set(id, openLink());
    stats.connects += 1;
    return id;
});
await page.exposeFunction("__bleDisconnect", (id) => {
    links.get(id)?.close();
    links.delete(id);
});
await page.exposeFunction("__bleWrite", (id, bytes) => {
    const link = links.get(id);
    if (!link) throw new Error("not connected");
    stats.writes += 1;
    const first = bytes[0] === 0x05 && bytes[1] === 0 && bytes[2] === 0 && bytes[5] === 0x80;
    if (first && [2, 7, 8].includes(bytes[6])) stats.signApdus += 1;
    if (first && bytes.length > 7 && (bytes[7] & 0x40) !== 0) stats.mlDsa65Apdus += 1;
    return link.write(bytes);
});
await page.addInitScript(FAKE_BLUETOOTH);
await page.goto("http://localhost:8080/dapp.html", { waitUntil: "load" });
await page.waitForFunction(() => !!window.nearConnector, null, { timeout: 20000 });
await page.waitForTimeout(1500);
const exec = () => page.frames().find((f) => f !== page.mainFrame());
/// The executor's frame once it shows `selector`: near-connect opens a new iframe for each
/// request, a moment after it, and the one of the request before may still be there, detaching.
async function waitForExecutor(selector, timeoutMs = 60000) {
    const started = Date.now();
    while (Date.now() - started < timeoutMs) {
        const frame = exec();
        try {
            if (frame && (await frame.$(selector))) return frame;
        } catch {
            // Detached: the next poll finds the new one.
        }
        await page.waitForTimeout(250);
    }
    throw new Error(`no executor iframe with ${selector}`);
}
const dappLog = async () => (await page.textContent("#log")).trim();

// 1. Connect with the classic key: the connect screen, then the request screen, which offers
// Bluetooth.
await page.click("#connect");
await page.waitForTimeout(1500);
await page.locator('.connect-item[data-type="near-signer-qr"]').first().click();
await page.waitForTimeout(2000);
let frame = exec();
check(
    await frame.evaluate(() => typeof navigator.bluetooth === "object"),
    "the fake navigator.bluetooth is not in the iframe",
);
await frame.click('label[for="type-ed25519"]');
await frame.click("#next");
await page.waitForTimeout(600);
check(await frame.isVisible("#code"), "the camera screen did not come up first");
check(await frame.isVisible("#bluetooth"), "the request screen does not offer Bluetooth");
console.log("request screen offers:", (await frame.textContent("#bluetooth")).trim());
await frame.click("#bluetooth");
await page.waitForTimeout(400);
console.log(
    "Bluetooth screen:",
    (await frame.textContent(".title")).trim(),
    "|",
    (await frame.textContent(".lead")).replace(/\s+/g, " ").trim().slice(0, 90),
);
check(await frame.isVisible("#connect"), "no Connect over Bluetooth button");
check(await frame.isVisible("#camera-instead"), "no way back to the camera");
await shot(page, "ble-connect-screen");

// A cancelled chooser: said on the screen, the button back.
await frame.evaluate(() => {
    window.__bleCancelNext = true;
});
await frame.click("#connect");
await page.waitForTimeout(500);
const cancelled = (await frame.textContent("#error")).trim();
console.log("cancelled chooser:", cancelled);
check(/No phone chosen/.test(cancelled), "a cancelled chooser is not explained");
check(!(await frame.$eval("#connect", (b) => b.disabled)), "the Connect button stayed disabled");
await shot(page, "ble-chooser-cancelled");

// The real thing: the status lines (recorded in the page, as the simulator answers faster than
// a poll would see them), then the account list.
await frame.evaluate(() => {
    window.__statuses = [];
    const target = document.getElementById("status");
    new MutationObserver(() => {
        const text = target.textContent.trim();
        if (text && window.__statuses[window.__statuses.length - 1] !== text) window.__statuses.push(text);
    }).observe(target, { childList: true, characterData: true, subtree: true });
});
await frame.click("#connect");
await frame.waitForSelector("#list", { timeout: 30000 });
const statuses = await frame.evaluate(() => window.__statuses);
console.log("status lines:", statuses);
check(
    statuses.some((s) => /Connecting to NEAR Signer/.test(s)),
    "no connecting status",
);
check(
    statuses.some((s) => /share the address/.test(s)),
    "no waiting-for-the-phone status",
);
const rows = await frame.$$eval("#list .account", (buttons) => buttons.map((b) => b.dataset.account));
console.log("account list:", rows);
check(
    rows.some((id) => /^[0-9a-f]{64}$/.test(id)),
    "the implicit account of the simulator's key is not listed",
);
check(
    stats.connects === 1 && links.size === 0,
    `${stats.connects} connections, ${links.size} still open after the request`,
);
check(stats.mlDsa65Apdus === 0, "the classic key was asked for with the ML-DSA-65 bit");
await shot(page, "ble-accounts");
await frame.click("#list .account:last-child");
await page.waitForFunction(() => /^Signed in as/.test(document.getElementById("log").textContent), null, {
    timeout: 20000,
});
console.log("dapp log:", (await dappLog()).split("\n")[0]);

// 2. A message to sign: the transport is remembered, so the request starts over Bluetooth.
await page.click("#sign-message");
frame = await waitForExecutor("#connect");
check(!(await frame.$("#code")), "the remembered transport did not skip the codes");
console.log("sign message over Bluetooth:", (await frame.textContent(".title")).trim());
const signBefore = stats.signApdus;
await frame.click("#connect");
await page.waitForFunction(() => /^(Signed message|Error)/.test(document.getElementById("log").textContent), null, {
    timeout: 60000,
});
const signedLog = await dappLog();
console.log("dapp log:", signedLog.replace(/\s+/g, " ").slice(0, 160));
check(/^Signed message:/.test(signedLog), `the message was not signed: ${signedLog.slice(0, 200)}`);
check(/"signature": "[A-Za-z0-9+/=]{80,}"/.test(signedLog), "no ed25519 signature in the dapp's log");
check(stats.signApdus - signBefore === 1, `${stats.signApdus - signBefore} signing APDUs for a short message`);
check(stats.connects === 2 && links.size === 0, "the second request did not connect once and disconnect");

// 3. Back to the camera: the codes come up, and Cancel ends the request.
await page.click("#sign-message");
frame = await waitForExecutor("#camera-instead");
await frame.click("#camera-instead");
await page.waitForTimeout(600);
check(await frame.isVisible("#code"), "the camera screen did not come back");
check(await frame.isVisible("#bluetooth"), "the camera screen lost its way to Bluetooth");
await shot(page, "ble-back-to-camera");
await frame.click("#cancel");
await page.waitForFunction(() => /^Error:/.test(document.getElementById("log").textContent), null, { timeout: 10000 });
console.log("after cancel:", (await dappLog()).slice(0, 80));

// The choice is remembered the other way round too: the next request shows the codes.
await page.click("#sign-message");
frame = await waitForExecutor("#code");
check(await frame.isVisible("#code"), "the camera choice was not remembered");
await frame.click("#cancel");
await page.waitForTimeout(800);

// 4. The quantum-safe key over Bluetooth: disconnect (which forgets the account type), connect
// again, where a new connection starts on Quantum-safe, switch to Bluetooth; every APDU for the
// key carries P1's bit 0x40 and the list offers the key's universal account.
const quantumKey = execFileSync(SIM, ["pubkey", "--key-type", "ml-dsa-65"], { stdio: ["ignore", "pipe", "ignore"] })
    .toString()
    .trim();
const zeroU = accountIdForPublicKey(quantumKey);
await page.click("#disconnect");
await page.waitForTimeout(1200);
await page.click("#connect");
await page.waitForTimeout(1500);
await page.locator('.connect-item[data-type="near-signer-qr"]').first().click();
frame = await waitForExecutor("#next");
const startsOn = await frame.$eval('input[name="account-type"]:checked', (radio) => radio.value);
console.log("connect screen starts on:", startsOn);
check(startsOn === "ml-dsa-65", `a new connection after a disconnect starts on ${startsOn}, not Quantum-safe`);
check((await frame.inputValue("#path")) === "44'/397'/0'/0'/1'", "the path changed with the account type");
await frame.click("#next");
await page.waitForTimeout(600);
await frame.click("#bluetooth");
await page.waitForTimeout(400);
const quantumBefore = stats.mlDsa65Apdus;
await frame.click("#connect");
await frame.waitForSelector("#list", { timeout: 30000 });
const quantumRows = await frame.$$eval("#list .account", (buttons) => buttons.map((b) => b.dataset.account));
console.log("quantum-safe account list:", quantumRows);
check(stats.mlDsa65Apdus - quantumBefore === 1, "get public key went without P1's bit 0x40");
check(quantumRows.includes(zeroU), `the list does not offer the key's universal account ${zeroU}`);
await shot(page, "ble-quantum-accounts");
await frame.click(`#list .account[data-account="${zeroU}"]`);
await page.waitForFunction((id) => document.getElementById("log").textContent.includes(`Signed in as ${id}`), zeroU, {
    timeout: 20000,
});
await page.click("#sign-message");
frame = await waitForExecutor("#connect");
const quantumSignBefore = stats.mlDsa65Apdus;
await frame.click("#connect");
await page.waitForFunction(() => /^(Signed message|Error)/.test(document.getElementById("log").textContent), null, {
    timeout: 60000,
});
const quantumLog = await dappLog();
console.log("dapp log:", quantumLog.replace(/\s+/g, " ").slice(0, 160));
check(/^Signed message:/.test(quantumLog), `the message was not signed: ${quantumLog.slice(0, 200)}`);
const quantumSignature = /"signature": "([A-Za-z0-9+/=]+)"/.exec(quantumLog)?.[1] ?? "";
check(
    Buffer.from(quantumSignature, "base64").length === 3309,
    `a ${Buffer.from(quantumSignature, "base64").length}-byte signature, not ML-DSA-65's 3309`,
);
check(quantumLog.includes(`"publicKey": "${quantumKey}"`), "the signed message does not name the ML-DSA-65 key");
check(stats.mlDsa65Apdus - quantumSignBefore === 1, "the signing APDU went without P1's bit 0x40");
console.log(
    "console:",
    logs
        .filter((l) => !/favicon/.test(l))
        .join(" || ")
        .slice(0, 600),
);
await browser.close();
sim.kill();
console.log("OK");
