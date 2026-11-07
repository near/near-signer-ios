// See lib.mjs for how to run these.
import { launch, shot, collectRequest, signWithSim, TRANSFER_TX, photoOf, fakeCamera } from "./lib.mjs";

const { browser, page, logs } = await launch();
await fakeCamera(page.context());
await page.goto("http://localhost:8080/", { waitUntil: "load" });
await page.selectOption("#kind", "transaction");
await page.fill("#payload", TRANSFER_TX);
await page.click("#start");
await page.waitForTimeout(600);
await shot(page, "index-running");
console.log("counter:", await page.textContent("#counter"));
console.log("hint:", await page.textContent("#hint"));
const { frames, misses } = await collectRequest(page);
console.log(`collected ${frames.length} frame(s), ${misses} unreadable canvas reads`);
const answer = await signWithSim(frames);
console.log("sim answer:", answer.length, "chars");

// A wrong code first.
await page.fill("#typed", answer.slice(0, -3) + "AAA");
await page.click("#check");
await page.waitForTimeout(300);
console.log("after typo:", (await page.textContent("#result")).trim().slice(0, 160));
await shot(page, "index-typo");

// Then the answer read from the (fake) camera.
await page.evaluate((text) => {
    window.__cameraCode = text;
}, answer);
await page.click("#camera");
await page.waitForFunction(() => /verified|WRONG|error/.test(document.getElementById("result").textContent), null, {
    timeout: 10000,
});
console.log("camera result:", (await page.textContent("#result")).trim().slice(0, 300));
console.log("counter after:", await page.textContent("#counter"));
await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
await shot(page, "index-result");

// A second request, answered with a photo of the code through the file chooser.
await page.click("#start");
await page.waitForTimeout(400);
const again = await collectRequest(page);
const answer2 = await signWithSim(again.frames);
const chooser = page.waitForEvent("filechooser");
await page.click("#photo");
await (await chooser).setFiles({ name: "answer.png", mimeType: "image/png", buffer: photoOf(answer2) });
await page.waitForFunction(() => /verified|WRONG|error/.test(document.getElementById("result").textContent), null, {
    timeout: 10000,
});
console.log("photo result:", (await page.textContent("#result")).trim().slice(0, 300));
console.log("console logs:", logs.join(" || ").slice(0, 600));
await browser.close();
