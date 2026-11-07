// Screenshots of every executor screen, cropped to the modal, into preview/. See lib.mjs for how to run.
import { launch, collectRequest, signWithSim, typeAnswer } from "./lib.mjs";

const { browser, page } = await launch({ width: 1100, height: 950 });
await page.goto("http://localhost:8080/dapp.html", { waitUntil: "load" });
await page.waitForFunction(() => !!window.nearConnector, null, { timeout: 20000 });
await page.waitForTimeout(1500);
const exec = () => page.frames().find((f) => f !== page.mainFrame());
let n = 0;
async function modalShot(name) {
    await page.mouse.move(5, 5);
    await page.waitForTimeout(400);
    const box = await page.locator(".hot-connector-popup .modal-content").first().boundingBox();
    await page.screenshot({
        path: `preview/${String(++n).padStart(2, "0")}-${name}.png`,
        clip: { x: box.x - 8, y: box.y - 8, width: box.width + 16, height: box.height + 16 },
    });
    console.log("shot", name);
}

await page.click("#connect");
await page.waitForTimeout(1500);
await modalShot("wallet-list");
await page.locator('.connect-item[data-type="near-signer-qr"]').first().click();
await page.waitForTimeout(2000);
await modalShot("connect-path");
let f = exec();
await f.click("#next");
await page.waitForTimeout(1000);
await modalShot("share-address-codes");
await typeAnswer(f, "this is not a code");
await f.click("#confirm");
await page.waitForTimeout(300);
await modalShot("wrong-code");
await typeAnswer(f, "");
const req = await collectRequest(f, { timeoutMs: 30000 });
const answer = await signWithSim(req.frames);
// All but the last letter, so the screen is still there to photograph; the full code goes through by itself.
await typeAnswer(
    f,
    answer
        .slice(0, -1)
        .replace(/(.{5})/g, "$1 ")
        .trim(),
);
await modalShot("answer-typed");
await typeAnswer(f, answer);
await page.waitForTimeout(3000);
await modalShot("choose-account");
await f.click("#list .account:last-child");
await page.waitForTimeout(2000);

await page.click("#send");
await page.waitForTimeout(3500);
f = exec();
await modalShot("sign-transaction-codes");
await f.click("#cancel");
await page.waitForTimeout(1000);
await page.click("#sign-message");
await page.waitForTimeout(2000);
await modalShot("sign-message-codes");
await browser.close();
