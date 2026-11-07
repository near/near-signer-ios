// See lib.mjs for how to run these.
import { launch, shot, collectRequest, signWithSim, confirmIfStill, typeAnswer } from "./lib.mjs";

const { browser, page, logs } = await launch({ width: 1100, height: 950 });
await page.goto("http://localhost:8080/dapp.html", { waitUntil: "load" });
await page.waitForFunction(() => !!window.nearConnector, null, { timeout: 20000 });
await page.waitForTimeout(1500);
const exec = () => page.frames().find((f) => f !== page.mainFrame());

// 1. Wrong code, bigger code, cancel.
await page.click("#connect");
await page.waitForTimeout(1500);
await page.locator('.connect-item[data-type="near-signer-qr"]').first().click();
await page.waitForTimeout(2000);
let f = exec();
await f.click("#next");
await page.waitForTimeout(800);
console.log(
    "code card width (21-byte request):",
    await f.$eval("#card", (c) => getComputedStyle(c).width),
    "| progress:",
    JSON.stringify(await f.textContent("#counter")),
);
await typeAnswer(f, "this is not a code");
await f.click("#confirm");
await page.waitForTimeout(300);
console.log("wrong code error:", (await f.textContent("#error")).trim());
await f.click("#back");
await page.waitForTimeout(300);
console.log(
    "after Back, code shown:",
    await f.isVisible("#code"),
    "| error:",
    JSON.stringify(await f.textContent("#error")),
);
await f.click("#cancel");
await page.waitForTimeout(1200);
console.log("after cancel, dapp log:", (await page.textContent("#log")).trim().slice(0, 120));
console.log("iframe still open:", !!exec());

// 2. Manual account that does not hold the key.
await page.click("#connect");
await page.waitForTimeout(1500);
await page.locator('.connect-item[data-type="near-signer-qr"]').first().click();
await page.waitForTimeout(2000);
f = exec();
await f.click("#next");
await page.waitForTimeout(800);
const req = await collectRequest(f, { timeoutMs: 30000 });
await typeAnswer(f, await signWithSim(req.frames));
await page.waitForTimeout(400);
await confirmIfStill(f);
await page.waitForTimeout(3000);
if (!(await f.$("details[open]"))) await f.click("summary");
await f.fill("#manual", "frolik.testnet");
await f.click("#use");
await page.waitForTimeout(4000);
console.log("manual account error:", (await f.textContent("#error").catch(() => "(no error element)")).trim());
await shot(page, "edge-manual-account");
await f.click("#list .account:last-child");
await page.waitForTimeout(2000);
console.log("signed in as:", (await page.textContent("#log")).trim().split("\n")[0]);

// 3. A big request: a 30 KB contract deployment as a delegate action, many codes in a loop. The
// canvas is read slower than the codes change, so the loop goes round more than once; the
// fountain code completes anyway.
await page.selectOption("#size", "30000");
await page.click("#deploy");
await page.waitForTimeout(3500);
f = exec();
console.log(
    "deploy screen h1:",
    await f.textContent(".title").catch(() => "(none)"),
    "| counter:",
    (await f.textContent("#counter").catch(() => "")).trim(),
);
await shot(page, "edge-deploy-codes");
const started = Date.now();
const deploy = await collectRequest(f, { timeoutMs: 120000 });
console.log(
    `deploy request: ${deploy.frames.length} frames used, ${deploy.misses} unreadable canvases, ${((Date.now() - started) / 1000).toFixed(1)} s`,
);
await typeAnswer(f, await signWithSim(deploy.frames));
await page.waitForTimeout(400);
await confirmIfStill(f);
await page.waitForTimeout(3000);
console.log("after deploy, dapp log:", (await page.textContent("#log")).trim().slice(0, 140));

// 4. A transaction: the executor fetches nonce and block, the phone signs, the executor sends.
await page.click("#send");
await page.waitForTimeout(3500);
f = exec();
console.log(
    "send screen h1:",
    await f.textContent(".title").catch(() => "(none)"),
    "| error:",
    (await f.textContent("#error").catch(() => "")).trim().slice(0, 200),
);
if (await f.$("#code")) {
    const tx = await collectRequest(f, { timeoutMs: 30000 });
    await typeAnswer(f, await signWithSim(tx.frames));
    await page.waitForTimeout(400);
    await confirmIfStill(f);
    await page.waitForTimeout(8000);
    const stillOpen = exec();
    console.log(
        "after confirm, executor open:",
        !!stillOpen,
        stillOpen
            ? "| h1: " +
                  (await stillOpen.textContent(".title").catch(() => "")) +
                  " | error: " +
                  (await stillOpen.textContent("#error").catch(() => "")).trim().slice(0, 300)
            : "",
    );
    await shot(page, "edge-send-result");
}
console.log("dapp log:", (await page.textContent("#log")).trim().slice(0, 500));
console.log(
    "console:",
    logs
        .filter((l) => !/favicon/.test(l))
        .join(" || ")
        .slice(0, 500),
);
await browser.close();
