// Browser tests of the camera transfer's web side, driven by Playwright: the pages are opened in a
// headless Chromium, the QR codes are read back from the canvas with jsQR, and near-signer-sim
// plays the phone. Not part of CI (they need a browser): see README.md, "Testing".
//
//   python3 -m http.server -d host/optical 8080 &      # the pages
//   swift build --product near-signer-sim               # the phone
//   cd host/optical/browser-test && npm install --no-save playwright-core jsqr pngjs
//   npx --yes playwright@1.56.1 install chromium       # or CHROME_BIN=/path/to/chrome
//   node test-index.mjs && node test-dapp.mjs && node test-dapp-edges.mjs
//
import { chromium } from "playwright-core";
import { PNG } from "pngjs";
import jsQR from "jsqr";
import { spawn } from "node:child_process";
import { Receiver } from "../optical.mjs";

const qrcode = (await import("../vendor/qrcode-generator.js")).default;

export const SIM = new URL("../../../.build/debug/near-signer-sim", import.meta.url).pathname;
export const TRANSFER_TX =
    "DQAAAGFsaWNlLnRlc3RuZXQAxXHjPi42wsco1hfqd6iOIyDIaX6si0Y638ASi5aCXL8HAAAAAAAAAAsAAABib2IudGVzdG5ldDlKvrNecHYJ3o9ztj1DvRo3b/5nk1yqaJN90pvATmc8AQAAAAMAAIBxZDO2KaM9AQAAAAAA";

export async function launch(viewport = { width: 1100, height: 900 }) {
    // CHROME_BIN points at a Chromium (Playwright's download works); unset, Playwright's default is used.
    const browser = await chromium.launch({
        ...(process.env.CHROME_BIN ? { executablePath: process.env.CHROME_BIN } : {}),
        args: ["--no-sandbox", "--disable-gpu"],
    });
    const context = await browser.newContext({ viewport, deviceScaleFactor: 1 });
    const page = await context.newPage();
    const logs = [];
    page.on("console", (m) => logs.push(`[${m.type()}] ${m.text()}`));
    page.on("pageerror", (e) => logs.push(`[pageerror] ${e.message}`));
    return { browser, page, logs };
}

/// Decodes the QR code drawn on a canvas inside `frame` (a page or an iframe).
export async function readCanvasCode(frame, selector = "#code") {
    const dataUrl = await frame.evaluate((sel) => document.querySelector(sel).toDataURL("image/png"), selector);
    const png = PNG.sync.read(Buffer.from(dataUrl.split(",")[1], "base64"));
    const code = jsQR(
        new Uint8ClampedArray(png.data.buffer, png.data.byteOffset, png.data.length),
        png.width,
        png.height,
    );
    return code?.data ?? null;
}

/// Watches the canvas until the receiver has the whole request; returns the frames it used.
export async function collectRequest(frame, { selector = "#code", timeoutMs = 60000 } = {}) {
    const receiver = new Receiver();
    const frames = [];
    const started = Date.now();
    let misses = 0;
    while (Date.now() - started < timeoutMs) {
        const text = await readCanvasCode(frame, selector);
        if (!text) {
            misses += 1;
            await new Promise((r) => setTimeout(r, 40));
            continue;
        }
        const outcome = receiver.receive(text);
        if (outcome.kind === "progress" || outcome.kind === "complete") frames.push(text);
        if (outcome.kind === "complete")
            return { frames, message: outcome.message, misses, sessionId: receiver.sessionId };
        await new Promise((r) => setTimeout(r, 30));
    }
    throw new Error(
        `request not complete after ${timeoutMs} ms (${frames.length} frames, ${misses} unreadable canvases)`,
    );
}

/// The phone, played by near-signer-sim: feeds it the frames, returns the answer text.
export function signWithSim(frames) {
    return new Promise((resolve, reject) => {
        const sim = spawn(SIM, ["optical", "--auto-approve"], { stdio: ["pipe", "pipe", "pipe"] });
        let out = "";
        let err = "";
        sim.stdout.on("data", (d) => (out += d));
        sim.stderr.on("data", (d) => (err += d));
        sim.on("close", (code) =>
            code === 0 ? resolve(out.trim()) : reject(new Error(`sim exit ${code}: ${err.slice(-400)}`)),
        );
        sim.stdin.write(frames.join("\n") + "\n");
        sim.stdin.end();
    });
}

export async function shot(page, name) {
    await (await import("node:fs")).promises.mkdir("shots", { recursive: true });
    await page.screenshot({ path: `shots/${name}.png`, fullPage: false });
    console.log("shot", name);
}

/// Types `text` as the phone's answer: the executor's answer screen comes after Continue, and it
/// keeps the field behind "type the letters under the code", so those are clicked first when the
/// field is still hidden.
export async function typeAnswer(frame, text) {
    if (await frame.isVisible("#continue")) await frame.click("#continue");
    if (!(await frame.isVisible("#typed"))) await frame.click("#type");
    await frame.fill("#typed", text);
}

/// Presses Confirm unless the answer already went through (a complete code is accepted as it is
/// typed, and the executor's frame may be gone by now).
export async function confirmIfStill(frame) {
    try {
        if (await frame.isVisible("#confirm")) await frame.click("#confirm");
    } catch {
        // The frame closed: the answer was accepted.
    }
}

/// A fake camera for every page of `context`: getUserMedia hands out a canvas stream showing a QR
/// code of `window.__cameraCode` (set it with page.evaluate), repainted so frames keep coming.
/// The vendored generator draws the code; the Chromium here has no BarcodeDetector, so the pages
/// read the frames with jsQR.
export async function fakeCamera(context) {
    const generator = await (
        await import("node:fs")
    ).promises.readFile(new URL("../vendor/qrcode-generator.js", import.meta.url), "utf8");
    await context.addInitScript({
        content: `${generator}
(() => {
    navigator.mediaDevices.getUserMedia = async () => {
        const canvas = document.createElement("canvas");
        canvas.width = 640;
        canvas.height = 480;
        const context = canvas.getContext("2d");
        const paint = () => {
            context.fillStyle = "#c8c6c3";
            context.fillRect(0, 0, 640, 480);
            if (!window.__cameraCode) return;
            const qr = qrcode(0, "L");
            qr.addData(window.__cameraCode, "Alphanumeric");
            qr.make();
            const n = qr.getModuleCount();
            const px = 6;
            const left = 320 - (n * px) / 2;
            const top = 240 - (n * px) / 2;
            context.fillStyle = "#fff";
            context.fillRect(left - 4 * px, top - 4 * px, (n + 8) * px, (n + 8) * px);
            context.fillStyle = "#111";
            for (let r = 0; r < n; r++)
                for (let c = 0; c < n; c++) if (qr.isDark(r, c)) context.fillRect(left + c * px, top + r * px, px, px);
        };
        paint();
        setInterval(paint, 100);
        return canvas.captureStream(10);
    };
})();`,
    });
}

/// A PNG "photo" of a QR code of `text`: a light grey picture of `width` × `height` with the code
/// `codePx` wide at `at`, about what a camera sees of the phone's screen.
export function photoOf(text, { width = 1600, height = 1200, codePx = 320, at = [880, 480] } = {}) {
    const qr = qrcode(0, "L");
    qr.addData(text, "Alphanumeric");
    qr.make();
    const modules = qr.getModuleCount();
    const quiet = 4;
    const px = codePx / (modules + 2 * quiet);
    const png = new PNG({ width, height });
    for (let i = 0; i < width * height; i++) png.data.set([205, 203, 200, 255], i * 4);
    for (let y = 0; y < codePx; y++) {
        for (let x = 0; x < codePx; x++) {
            const row = Math.floor(y / px) - quiet;
            const column = Math.floor(x / px) - quiet;
            const dark = row >= 0 && column >= 0 && row < modules && column < modules && qr.isDark(row, column);
            const value = dark ? 25 : 250;
            png.data.set([value, value, value, 255], ((at[1] + y) * width + at[0] + x) * 4);
        }
    }
    return PNG.sync.write(png);
}
