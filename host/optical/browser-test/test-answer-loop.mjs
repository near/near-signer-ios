// See lib.mjs for how to run these. The phone's answer as a loop of codes, which it shows when
// the answer is longer than one code (an ML-DSA-65 key or signature): read by the standalone
// page's camera, turned down from a photo, pasted as text, and read by the executor's camera page
// for the dapp, whose account list then offers the key's universal account and whose transfer
// asks for the account's first deposit. A stand-in 1952-byte key plays the phone's: no
// simulator, and nothing is sent to testnet.
import { collectRequest, fakeCamera, launch, photoOf, shot } from "./lib.mjs";
import { RESPONSE_PREFIX, Sender, encodeResponseBytes, parseFrame, responseText } from "../optical.mjs";
import { accountIdForPublicKey, publicKeyString } from "../borsh.mjs";

const KEY = Uint8Array.from({ length: 1952 }, (_, i) => (i * 13 + 7) % 256);
const keyText = publicKeyString(KEY);
const zeroU = accountIdForPublicKey(keyText);
console.log("stand-in key's account:", zeroU);

function check(condition, message) {
    if (!condition) throw new Error(`FAILED: ${message}`);
}

/// The answer to the request whose frames these are: the key, as the frames of a loop.
function answerLoop(requestFrames) {
    const sessionId = parseFrame(requestFrames[0]).sessionId;
    const bytes = encodeResponseBytes({ sessionId, status: 0x9000, result: KEY });
    const sender = new Sender(bytes, { sessionId: 0x5eed5eed, fragmentSize: 600, prefix: RESPONSE_PREFIX });
    const frames = Array.from({ length: sender.fragmentCount * 2 }, (_, s) => sender.frame(s));
    return { bytes, frames, count: sender.fragmentCount, text: responseText(bytes) };
}

/// Shows the loop on `target`'s fake camera, one frame every `everyMs`, until `until()` is true.
async function showLoop(target, frames, until, { everyMs = 400, timeoutMs = 40000 } = {}) {
    const started = Date.now();
    for (let s = 0; Date.now() - started < timeoutMs; s++) {
        await target.evaluate(
            (text) => {
                window.__cameraCode = text;
            },
            frames[s % frames.length],
        );
        await target.waitForTimeout(everyMs);
        if (await until()) return;
    }
    throw new Error("the loop was not read in time");
}

const { browser, page, logs } = await launch({ width: 1100, height: 950 });
await fakeCamera(page.context());

// 1. The standalone page: a public key request (Quantum-safe is the choice it starts with, so the
// instruction is 44), answered with the loop through the camera.
await page.goto("http://localhost:8080/", { waitUntil: "load" });
await page.selectOption("#kind", "publicKey");
check(await page.isChecked("#type-ml-dsa-65"), "the standalone page does not start on Quantum-safe");
await page.click("#start");
await page.waitForTimeout(400);
const request = await collectRequest(page);
check(request.message[0] === 0x44, `the page's key request starts with ${request.message[0].toString(16)}, not 44`);
const loop = answerLoop(request.frames);
console.log(`answer: ${loop.bytes.length} bytes, ${loop.count} frames, ${loop.text.length} characters of text`);
await page.click("#camera");
let progressSeen = "";
await showLoop(page, loop.frames, async () => {
    const result = await page.textContent("#result");
    if (/Reading the answer/.test(result)) progressSeen = result.trim();
    return /publicKey|error|WRONG/.test(result);
});
const result = (await page.textContent("#result")).trim();
console.log("progress seen:", progressSeen || "(none)");
console.log("camera result:", result.slice(0, 200).replace(/\n/g, " "));
check(result.includes(`"publicKey": "${keyText}"`), "the key is not shown as ml-dsa-65:…");
check(result.includes(`"accountId": "${zeroU}"`), "the universal account id is not shown");
await shot(page, "loop-index-result");

// A photo holds one frame of the loop: turned down with the way out; the text pasted goes through.
await page.click("#start");
await page.waitForTimeout(400);
const again = answerLoop((await collectRequest(page)).frames);
const chooser = page.waitForEvent("filechooser");
await page.click("#photo");
await (
    await chooser
).setFiles({
    name: "frame.png",
    mimeType: "image/png",
    buffer: photoOf(again.frames[0], { codePx: 720, at: [440, 240] }),
});
await page.waitForFunction(
    () => /longer than one code|error|publicKey/.test(document.getElementById("result").textContent),
    null,
    {
        timeout: 15000,
    },
);
const photoResult = (await page.textContent("#result")).trim();
console.log("photo of one frame:", photoResult.slice(0, 120));
check(/longer than one code/.test(photoResult), "a photo of one frame should say the answer is longer than one code");
await page.fill("#typed", again.text);
await page.click("#check");
await page.waitForTimeout(500);
const pasted = (await page.textContent("#result")).trim();
console.log("pasted text:", pasted.slice(0, 100).replace(/\n/g, " "));
check(pasted.includes(`"accountId": "${zeroU}"`), "the pasted text did not go through");

// 2. The dapp: the executor's public key request, answered with the loop through the camera
// page; the account list offers the key's universal account; a transfer from it asks for the
// first deposit, since the account does not exist.
await page.goto("http://localhost:8080/dapp.html", { waitUntil: "load" });
await page.waitForFunction(() => !!window.nearConnector, null, { timeout: 20000 });
await page.waitForTimeout(1500);
await page.click("#connect");
await page.waitForTimeout(1500);
await page.locator('.connect-item[data-type="near-signer-qr"]').first().click();
await page.waitForTimeout(2000);
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
let frame = exec();
// The connect screen: a new connection starts on Quantum-safe; the account type is a real radio
// group (the arrow keys move it) and leaves the path alone, which is the same for both types.
check(await frame.isChecked("#type-ml-dsa-65"), "a new connection does not start on Quantum-safe");
await frame.focus("#type-ml-dsa-65");
await page.keyboard.press("ArrowDown");
check(await frame.isChecked("#type-ed25519"), "the arrow key did not move the choice to Classic");
check((await frame.inputValue("#path")) === "44'/397'/0'/0'/1'", "the account type changed the path");
await page.keyboard.press("ArrowUp");
check(await frame.isChecked("#type-ml-dsa-65"), "the arrow key did not move the choice back to Quantum-safe");
const cards = await frame.$$eval(".choice", (labels) =>
    labels.map((label) => ({
        text: label.textContent.replace(/\s+/g, " ").trim(),
        clipped: [...label.querySelectorAll("span")].some((span) => span.scrollWidth > span.clientWidth + 1),
    })),
);
console.log(
    "account types:",
    cards.map((card) => card.text),
);
check(
    cards.every((card) => !card.clipped),
    "an account type's text is clipped",
);
await frame.click("#next");
await page.waitForTimeout(800);
const keyRequest = await collectRequest(frame, { timeoutMs: 30000 });
check(
    keyRequest.message[0] === 0x44,
    `the executor's key request starts with ${keyRequest.message[0].toString(16)}, not 44`,
);
const keyLoop = answerLoop(keyRequest.frames);

// A photo of one frame first: turned down, with the camera and pasting as the ways.
const popupPromise = page.waitForEvent("popup");
await frame.click("#continue");
const popup = await popupPromise;
await popup.waitForLoadState("load");
const photoChooser = page.waitForEvent("filechooser");
await frame.click("#photo-link");
await (
    await photoChooser
).setFiles({
    name: "frame.png",
    mimeType: "image/png",
    buffer: photoOf(keyLoop.frames[1], { codePx: 720, at: [440, 240] }),
});
await page.waitForTimeout(2000);
const photoError = (await frame.textContent("#error")).trim();
console.log("executor, photo of one frame:", photoError);
check(/longer than one code/.test(photoError), "the executor should turn down a photo of one frame");

// The camera page reads the loop, counting the frames, and closes once the executor has the key.
await popup.waitForFunction(() => /Looking for the code/.test(document.getElementById("status").textContent), null, {
    timeout: 10000,
});
let pageProgress = "";
const closed = popup.waitForEvent("close", { timeout: 20000 });
await showLoop(popup, keyLoop.frames, async () => {
    const status = await popup.evaluate(() => document.getElementById("status")?.textContent ?? "").catch(() => "");
    if (/Reading the answer/.test(status)) {
        if (status !== pageProgress) console.log("camera page:", status.trim());
        pageProgress = status;
    }
    return popup.isClosed() || (await popup.evaluate(() => document.body.classList.contains("done")).catch(() => true));
});
console.log("camera page progress seen:", Boolean(pageProgress));
check(pageProgress, "the camera page never counted the frames");
await closed;
console.log("camera page closed");
await frame.waitForSelector("#list", { timeout: 30000 });
const rows = await frame.$$eval("#list .account", (buttons) =>
    buttons.map((button) => ({
        id: button.dataset.account,
        note: button.querySelector(".account-note")?.textContent ?? "",
    })),
);
console.log("account list:", rows);
const own = rows.find((row) => /Quantum-safe/.test(row.note));
check(own && own.id === zeroU, "the list does not offer the key's universal account");
console.log("key shown:", (await frame.textContent(".subtitle")).replace(/\s+/g, " ").trim());
await shot(page, "loop-dapp-accounts");
await frame.click(`#list .account[data-account="${zeroU}"]`);
await page.waitForFunction((id) => document.getElementById("log").textContent.includes(`Signed in as ${id}`), zeroU, {
    timeout: 20000,
});
console.log("dapp log:", (await page.textContent("#log")).trim().split("\n")[0]);

await page.click("#send");
frame = await waitForExecutor("#account");
const title = (await frame.textContent(".title")).trim();
const shown = (await frame.inputValue("#account")).trim();
console.log("deposit screen:", title, "|", shown);
check(title === "Fund the account first" && shown === zeroU, "the deposit screen is wrong");
await shot(page, "loop-dapp-fund-first");
await frame.click("#cancel");
await page.waitForFunction(() => /^Error:/.test(document.getElementById("log").textContent), null, { timeout: 10000 });
const log = (await page.textContent("#log")).trim();
console.log("after cancel:", log.slice(0, 200));
check(log.includes(`Send NEAR to ${zeroU} first`), "the cancel message does not name the deposit");
console.log(
    "console:",
    logs
        .filter((l) => !/favicon/.test(l))
        .join(" || ")
        .slice(0, 600),
);
await browser.close();
console.log("OK");
