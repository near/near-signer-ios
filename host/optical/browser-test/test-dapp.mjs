// See lib.mjs for how to run these.
import { launch, shot, collectRequest, signWithSim, confirmIfStill, photoOf, typeAnswer, fakeCamera } from "./lib.mjs";

const { browser, page, logs } = await launch({ width: 1100, height: 950 });
await fakeCamera(page.context());
await page.goto("http://localhost:8080/dapp.html", { waitUntil: "load" });
await page.waitForFunction(() => !!window.nearConnector, null, { timeout: 20000 });
await page.waitForTimeout(1500);
console.log("log:", (await page.textContent("#log")).trim().slice(0, 200));
await shot(page, "dapp-initial");

await page.click("#connect");
await page.waitForTimeout(2500);
await shot(page, "dapp-wallet-list");
// Find our wallet in near-connect's popup (it may render in the page or in an iframe).
const frames = () => page.frames().map((f) => f.url().slice(0, 60));
console.log("frames:", frames());
const entry = page.locator('.connect-item[data-type="near-signer-qr"]').first();
await entry.click({ timeout: 10000 });
await page.waitForTimeout(2500);
await shot(page, "dapp-executor-path");
console.log("frames after click:", frames());
const exec = page.frames().find((f) => f !== page.mainFrame());
if (!exec) throw new Error("no executor iframe");
console.log("executor h1:", await exec.textContent(".title").catch(() => "(none)"));
console.log("executor path value:", await exec.inputValue("#path").catch(() => "(no #path)"));
await exec.click("#next");
await page.waitForTimeout(1200);
await shot(page, "dapp-executor-pubkey-codes");
console.log("counter:", await exec.textContent("#counter").catch(() => "(none)"));
const first = await collectRequest(exec, { timeoutMs: 30000 });
console.log("pubkey request frames:", first.frames.length);
const answer1 = await signWithSim(first.frames);
console.log("code screen:", (await exec.textContent("#show .lead")).replace(/\s+/g, " ").trim());
await typeAnswer(exec, answer1);
await page.waitForTimeout(400);
await confirmIfStill(exec);
await page.waitForTimeout(3000);
await shot(page, "dapp-executor-accounts");
console.log("accounts screen h1:", await exec.textContent(".title").catch(() => "(none)"));
console.log(
    "account list:",
    (await exec.textContent("#list").catch(() => "(none)")).replace(/\s+/g, " ").slice(0, 300),
);
const implicit = exec.locator("#list .account").first();
await implicit.click({ timeout: 5000 });
await page.waitForTimeout(2500);
await shot(page, "dapp-signed-in");
console.log("dapp log after sign-in:", (await page.textContent("#log")).trim().slice(0, 300));

// Sign a message through the executor, answering with a photo of the phone's code.
await page.click("#sign-message");
await page.waitForTimeout(2000);
const exec2 = page.frames().find((f) => f !== page.mainFrame());
await shot(page, "dapp-sign-message-codes");
console.log(
    "sign-message h1:",
    await exec2.textContent(".title").catch(() => "(none)"),
    "| counter:",
    await exec2.textContent("#counter").catch(() => ""),
);
const second = await collectRequest(exec2, { timeoutMs: 30000 });
console.log("message request frames:", second.frames.length);
const answer2 = await signWithSim(second.frames);

// Continue brings the answer screen up and opens the camera page in a window of its own (through
// near-connect, which relays what it reads).
const popupPromise = page.waitForEvent("popup");
await exec2.click("#continue");
const popup = await popupPromise;
await popup.waitForLoadState("load");
console.log("camera page:", popup.url(), "|", (await popup.title()).trim());
await page.waitForTimeout(500);
console.log(
    "answer screen:",
    (await exec2.textContent("#answer")).replace(/\s+/g, " ").trim().slice(0, 200),
    "| camera button hidden:",
    await exec2.$eval("#camera", (button) => button.hidden),
);
await shot(page, "dapp-executor-answer-screen");

// The photo way opens a file chooser even in the sandbox: a photo of the earlier request's answer
// is turned down.
const wrongChooser = page.waitForEvent("filechooser");
await exec2.click("#photo-link");
await (await wrongChooser).setFiles({ name: "old.png", mimeType: "image/png", buffer: photoOf(answer1) });
await page.waitForTimeout(1500);
console.log("photo of another request's answer:", (await exec2.textContent("#error")).trim());
await shot(page, "dapp-sign-message-wrong-photo");

// The camera page: the fake camera shows the earlier answer first, then the right one; the page
// closes once the executor has it.
await popup.waitForFunction(() => /Looking for the code/.test(document.getElementById("status").textContent), null, {
    timeout: 10000,
});
await popup.evaluate((text) => {
    window.__cameraCode = text;
}, answer1);
await popup.waitForFunction(() => /another request/.test(document.getElementById("status").textContent), null, {
    timeout: 10000,
});
console.log("camera page, another request's answer:", (await popup.textContent("#status")).trim());
console.log(
    "camera page frame:",
    await popup.evaluate(() => {
        const settings = document.getElementById("video").srcObject?.getVideoTracks()[0]?.getSettings?.() ?? {};
        const transform = getComputedStyle(document.getElementById("video")).transform;
        return `${document.getElementById("frame").className} | facingMode=${settings.facingMode} | video transform ${transform}`;
    }),
);
console.log("executor error line:", (await exec2.textContent("#error")).trim());
await shot(popup, "dapp-camera-page");
const closed = popup.waitForEvent("close", { timeout: 10000 });
await popup.evaluate((text) => {
    window.__cameraCode = text;
}, answer2);
await popup.waitForFunction(() => document.body.classList.contains("done"), null, { timeout: 10000 });
console.log("camera page, the right answer:", (await popup.textContent("#status")).trim());
await popup.waitForTimeout(800); // the check mark has drawn, the window is still there
await shot(popup, "dapp-camera-page-done");
await closed;
console.log("camera page closed after the right answer");
await page.waitForTimeout(2500);
await shot(page, "dapp-sign-message-result");
console.log("dapp log after sign-message:", (await page.textContent("#log")).trim().slice(0, 400));
console.log(
    "console:",
    logs
        .filter((l) => !/favicon/.test(l))
        .join(" || ")
        .slice(0, 800),
);
await browser.close();
