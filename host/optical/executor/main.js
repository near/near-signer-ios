// NEAR Signer camera executor for near-connect: the request goes to the phone as a loop of QR
// codes, the answer comes back as one QR code (see README.md "Camera transfer"). No Bluetooth,
// no USB: the phone's camera is the only input, and a camera on this side (live, or a photo taken
// in place on a phone or tablet), or typing, the way back.
//
// This file is the executor's own code. scripts/build-optical-executor.mjs bundles it with the
// codec (optical.mjs, qr.mjs, borsh.mjs) and the vendored QR generator into the single file
// near-connect loads, host/optical/near-signer-qr-executor.js. Its manifest entry (the schema of
// near-connect 0.11; every field below is required by `registerDebugWallet`):
//
//   {
//     "id": "near-signer-qr",
//     "name": "NEAR Signer",
//     "icon": "https://<your host>/icon.png",
//     "description": "An iPhone as a hardware wallet, through QR codes: no Bluetooth, no USB.",
//     "website": "https://github.com/near/near-signer-ios",
//     "version": "1.0.0",
//     "executor": "https://<your host>/near-signer-qr-executor.js",
//     "type": "sandbox",
//     "platform": {},
//     "features": { "signMessage": true, "signInWithoutAddKey": true, "signInAndSignMessage": true,
//                   "signInWithFunctionCallKey": true, "signAndSendTransaction": true,
//                   "signAndSendTransactions": true, "signDelegateActions": true,
//                   "mainnet": true, "testnet": true },
//     "permissions": { "storage": true, "allowsOpen": ["https://<your host>/near-signer-qr-camera.html"] }
//   }
//
// `allowsOpen` is the camera page, served next to the executor; without it near-connect refuses
// to open the page and the executor says so, leaving a photo and typing. The host must serve the
// page as HTML (GitHub's raw URLs serve text).
//
// near-connect's sandbox gives the iframe no camera: its origin is opaque, and a browser refuses
// getUserMedia there whatever the iframe's `allow` says (Chrome: "Invalid security origin"). So the
// phone's answer is read by the camera page, near-signer-qr-camera.html (built from camera.html and
// camera.js here), which the executor opens in a window of its own through near-connect's
// `window.selector.open`: the manifest's `allowsOpen` names it, and near-connect relays what the
// window posts to its opener back into this iframe. On a phone or tablet the first way is a photo
// taken in place instead: the file chooser needs no permission and opens the camera there. Reading
// a photo and typing the letters under the code stay as the other ways (scan.mjs reads photos).

const STORAGE_ACCOUNTS = "near-signer-qr:accounts";
const STORAGE_PATH = "near-signer-qr:derivationPath";
const DEFAULT_PATH = "44'/397'/0'/0'/1'";
const RPC_URLS = { mainnet: "https://free.rpc.fastnear.com", testnet: "https://test.rpc.fastnear.com" };
const ACCOUNT_APIS = { mainnet: "https://api.mainnet.fastnear.com", testnet: "https://api.testnet.fastnear.com" };
const MAX_BLOCK_HEIGHT_INCREMENT = 900n; // about 15 minutes, for delegate actions

const FPS = 20;

// MARK: - Screens

const STYLE = `<style>
  :root { color-scheme: dark; --bg: #1d1f20; --card: rgba(255, 255, 255, 0.05); --line: rgba(255, 255, 255, 0.15);
          --text: #fff; --muted: #ada5a4; --accent: #00d4aa; --accent-ink: #06211a; --danger: #ff6b6b; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.45 system-ui, -apple-system, sans-serif; }
  .panel { max-width: 440px; margin: 0 auto; padding: 20px 18px 18px; }
  .header { text-align: center; margin-bottom: 10px; }
  .title { font-size: 19px; font-weight: 600; margin: 0 0 4px; }
  .subtitle { color: var(--muted); font-size: 13px; margin: 0; overflow-wrap: anywhere; }
  .account-id { display: block; margin-top: 4px; font-family: ui-monospace, Menlo, monospace; font-size: 12.5px; color: var(--text); word-break: break-all; }
  .code-card { background: #fff; border-radius: 12px; padding: 8px; width: 216px; max-width: 100%; margin: 14px auto 0; box-sizing: border-box; }
  canvas { width: 100%; aspect-ratio: 1; display: block; }
  .progress { color: var(--muted); font-size: 12px; margin: 8px 0 0; text-align: center; font-variant-numeric: tabular-nums; }
  .progress:empty { display: none; }
  /* One line that says what to do now, under the code and on the answer screen. */
  .lead { color: var(--muted); font-size: 13px; line-height: 1.5; text-align: center; margin: 12px 0 0; text-wrap: pretty; }
  .lead b { color: var(--text); font-weight: 600; white-space: nowrap; }
  [hidden] { display: none !important; }
  .alternatives { color: var(--muted); font-size: 12px; margin: 8px 0 0; text-align: center; }
  .nobreak { white-space: nowrap; }
  .linkish { background: none; border: 0; color: var(--accent); font: inherit; cursor: pointer; padding: 0; }
  input, textarea { font: inherit; width: 100%; box-sizing: border-box; background: rgba(255, 255, 255, 0.05); color: var(--text); border: 1px solid var(--line); border-radius: 10px; padding: 11px 12px; outline: none; }
  input:focus, textarea:focus { border-color: var(--accent); }
  textarea.answer { font-family: ui-monospace, Menlo, monospace; font-size: 13px; letter-spacing: 0.5px; text-transform: uppercase; min-height: 50px; resize: none; }
  .btn { display: block; width: 100%; font: inherit; font-weight: 600; font-size: 15px; padding: 12px; border-radius: 12px; border: 0; cursor: pointer; margin-top: 10px; background: var(--accent); color: var(--accent-ink); }
  .btn:disabled { opacity: 0.5; cursor: default; }
  .btn-text { background: none; border: 0; color: var(--muted); font: inherit; font-size: 13px; cursor: pointer; display: block; margin: 6px auto 0; padding: 6px 10px; }
  .btn-text:hover { color: var(--text); }
  .row { display: flex; justify-content: center; gap: 8px; }
  .row .btn-text { margin: 6px 0 0; }
  .spinner.small { width: 22px; height: 22px; border-width: 2.5px; margin: 16px auto 0; }
  .error { color: var(--danger); font-size: 13px; margin: 8px 0 0; }
  .error:empty { display: none; }
  .list { display: flex; flex-direction: column; gap: 8px; margin-top: 12px; }
  button.account { font: inherit; text-align: left; width: 100%; padding: 11px 12px; border: 1px solid var(--line); border-radius: 12px; background: var(--card); color: var(--text); cursor: pointer; display: flex; align-items: center; gap: 10px; }
  button.account:hover { background: rgba(255, 255, 255, 0.08); }
  .account-name { flex: 1; min-width: 0; font-family: ui-monospace, Menlo, monospace; font-size: 13px; overflow-wrap: anywhere; }
  .account-note { color: var(--muted); font-size: 11.5px; font-family: system-ui, -apple-system, sans-serif; display: block; margin-top: 2px; }
  .chevron { color: var(--muted); flex: none; font-size: 18px; line-height: 1; }
  details { margin-top: 12px; }
  summary { cursor: pointer; color: var(--muted); font-size: 13px; list-style: none; }
  summary::before { content: "\\203A"; display: inline-block; width: 14px; transition: transform 0.15s; }
  details[open] summary::before { transform: rotate(90deg); }
  details[open] summary { margin-bottom: 8px; }
  .field-label { font-size: 12px; color: var(--muted); margin: 8px 0 6px; display: block; }
  .spinner { width: 28px; height: 28px; border: 3px solid var(--line); border-top-color: var(--accent); border-radius: 50%; margin: 28px auto 14px; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .muted { color: var(--muted); font-size: 12px; }
</style>`;

function showScreen(html) {
    document.body.innerHTML = `${STYLE}<div class="panel">${html}</div>`;
    return (id) => document.getElementById(id);
}

/// A centered title and a muted line under it, as near-connect's own screens have.
function header(title, subtitle = "") {
    return `<div class="header"><h2 class="title">${escapeHtml(title)}</h2>${subtitle ? `<p class="subtitle">${subtitle}</p>` : ""}</div>`;
}

/// Something is happening that the person can't influence: say what, with a spinner.
async function showLoading(title, hint = "") {
    await window.selector.ui.showIframe();
    showScreen(`${header(title, escapeHtml(hint))}<div class="spinner"></div>`);
}

/// "ed25519:EHk3…2iSz", the whole key as a tooltip.
function shortKey(publicKey) {
    const [prefix, key] = publicKey.split(":");
    return key && key.length > 14 ? `${prefix}:${key.slice(0, 6)}…${key.slice(-4)}` : publicKey;
}

function escapeHtml(text) {
    return String(text).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

async function sha256(bytes) {
    return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

/// Checks the phone's signature before it is used. A browser without Ed25519 in WebCrypto can't
/// check it, so nothing is signed there: the signature is never passed on unchecked.
async function verifySignature(publicKey, digest, signature) {
    let key;
    try {
        key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
    } catch {
        throw new Error(
            "This browser can't check the phone's signature (it has no Ed25519). Use a current Chrome, Edge, Firefox or Safari.",
        );
    }
    if (!(await crypto.subtle.verify("Ed25519", key, signature, digest))) {
        throw new Error("The phone's signature does not verify against the account's key.");
    }
}

// MARK: - The transfer

/// Shows `request` to the phone and resolves with the response's result bytes. Rejects with a
/// readable error on cancel, rejection or any other status.
/// `account` is the account the request is about (receiver, app), shown on its own line in
/// monospace so a 64-character implicit id wraps instead of running off the screen.
async function requestFromPhone({ kind, path, payload = new Uint8Array(0), title, detail, account }) {
    await window.selector.ui.showIframe();
    const deflated = await deflateIfSmaller(payload);
    return new Promise((resolve, reject) => {
        const message = encodeRequest({ kind, path, payload, deflated });
        let sender;
        let sequence = 0;
        let timer = null;
        let panel = null; // the camera page's window, while it is open
        let done = false;

        // Two screens, one thing to do on each. First the code alone, with what to do on the phone
        // and Continue. Then the phone's answer, read by a camera first: Continue itself opens the
        // camera page in a window of its own on a computer (this iframe has none, see the top of
        // the file), or takes a photo in place on a phone or tablet. Reading a photo and typing the
        // letters stay as the other ways under it, and Back brings the code up again.
        const touch = isTouchDevice();
        const cameraPage = cameraPageUrl();
        const live = Boolean(cameraPage) && !touch;
        const others = [
            !live && cameraPage ? `<button class="linkish" id="camera-link" type="button">scan it live</button>` : "",
            live ? `read it <button class="linkish" id="photo-link" type="button">from a photo</button>` : "",
            `<button class="linkish" id="type" type="button">type the letters under the code</button>`,
        ].filter(Boolean);
        // Each way on one line, its full stop with it: a line never breaks before the ".".
        const alternatives = others
            .map((item, i) => `<span class="nobreak">${item}${i === others.length - 1 ? "." : ""}</span>`)
            .join(" or ");
        const $ = showScreen(`
            ${header(title, `${escapeHtml(detail)}${account ? `<span class="account-id">${escapeHtml(account)}</span>` : ""}`)}
            <div id="show">
                <div class="code-card" id="card"><canvas id="code" width="800" height="800"></canvas></div>
                <p class="progress" id="counter"></p>
                <p class="lead">On the iPhone, open NEAR Signer, tap <b>Scan from computer</b> and point it at this code. Approve there, then continue with the phone's answer.</p>
                <button class="btn" id="continue" type="button">Continue</button>
            </div>
            <div id="answer" hidden>
                <div class="spinner small" id="waiting" hidden></div>
                <p class="lead" id="lead"></p>
                <button class="btn" id="camera" type="button" hidden>Open the camera</button>
                <button class="btn" id="photo" type="button" hidden>${touch ? "Take a photo" : "Choose a photo"}</button>
                <p class="alternatives">Or ${alternatives}</p>
                <input id="file" type="file" accept="image/*" capture="environment" hidden aria-label="A photo of the phone's QR code">
                <div id="typing" hidden>
                    <textarea id="typed" class="answer" rows="2" placeholder="ABCDE FGHIJ …" autocomplete="off" spellcheck="false" autocapitalize="characters" aria-label="The phone's answer"></textarea>
                    <button class="btn" id="confirm" type="button">Confirm</button>
                </div>
            </div>
            <p class="error" id="error" aria-live="polite"></p>
            <div class="row">
                <button class="btn-text" id="back" type="button" hidden>Back</button>
                <button class="btn-text" id="cancel" type="button">Cancel</button>
            </div>
        `);
        const canvas = $("code");
        const context = canvas.getContext("2d");

        const draw = () => {
            const matrix = qrMatrix(sender.frame(sequence));
            // The canvas holds whole modules, up to 800 pixels: the code fills it to its quiet
            // zone, with no rim of white left over from rounding.
            const modules = matrix.size + 8;
            const side = modules * Math.max(1, Math.floor(800 / modules));
            if (canvas.width !== side) canvas.width = canvas.height = side;
            drawCanvas(context, matrix, { size: side });
            sequence += 1;
        };
        const start = () => {
            if (timer) clearInterval(timer);
            sequence = 0;
            draw();
            // One code stands still: every frame would carry the same piece.
            if (sender.fragmentCount > 1) timer = setInterval(draw, Math.round(1000 / FPS));
        };
        // The code's size follows the width there is and the payload: the most bytes per code
        // whose code the card fits at the camera's density, and a small request gets a small code
        // instead of a wall of white. Called again when the width changes (a rotation, a narrower
        // browser): a change of bytes per code re-cuts the request, and the phone starts over.
        const card = $("card");
        let available = 0;
        const fit = () => {
            // Off the screen (the answer screen is up) there is no width to fit: the code waits.
            const width = card.parentElement.clientWidth || (sender ? 0 : 340);
            if (!width || (width === available && sender)) return;
            available = width;
            const wanted = fittingFragmentSize(available);
            if (!sender || Math.min(wanted, message.length) !== sender.fragmentSize) {
                sender = new Sender(message, { sessionId: sender?.sessionId, fragmentSize: wanted });
                start();
            }
            const modules = qrMatrix(sender.frame(0)).size;
            card.style.width = `${sender.fragmentCount > 1 ? available : codeWidth(modules, available)}px`;
            $("counter").textContent =
                sender.fragmentCount > 1
                    ? `${sender.fragmentCount} codes in a loop. Keep the phone on them until it has all ${sender.fragmentCount}.`
                    : "";
        };
        let settle = null;
        const observer =
            typeof ResizeObserver === "function"
                ? new ResizeObserver(() => {
                      clearTimeout(settle);
                      settle = setTimeout(fit, 300);
                  })
                : null;
        // The camera page hears how its last code fared; `done` tells it to close.
        const tell = (finished, message) => {
            try {
                panel?.postMessage({ method: "near-signer-qr:result", done: finished, message }, "*");
            } catch {
                // The window is gone.
            }
        };
        const finish = (callback, note = "Answer received.") => {
            if (done) return;
            done = true;
            clearInterval(timer);
            clearTimeout(settle);
            observer?.disconnect();
            window.removeEventListener("message", onMessage);
            // The camera page closes itself once it has shown the outcome.
            tell(true, note);
            panel = null;
            callback();
        };

        fit();
        observer?.observe(card.parentElement);

        // The answer screen follows the state: which way comes first, and whether the camera
        // window is up (`opening`: it is on its way, no button in the meantime).
        const syncAnswer = (opening = false) => {
            const open = live && (panel !== null || opening);
            $("waiting").hidden = !open;
            $("lead").textContent = open
                ? "Hold the QR code on the phone up to the camera window."
                : live
                  ? "Open the camera and hold the QR code on the phone up to it."
                  : touch
                    ? "Take a photo of the QR code on the phone."
                    : "Choose a photo of the QR code on the phone.";
            $("camera").hidden = !live || open;
            $("photo").hidden = live;
        };
        // The code's loop pauses while the code is off the screen; Back starts it again.
        const showAnswer = (opening = false) => {
            if (!$("answer").hidden) return;
            $("show").hidden = true;
            $("answer").hidden = false;
            $("back").hidden = false;
            clearInterval(timer);
            timer = null;
            syncAnswer(opening);
        };
        const showCode = () => {
            $("answer").hidden = true;
            $("back").hidden = true;
            $("show").hidden = false;
            $("error").textContent = "";
            start();
        };
        const showTyping = () => {
            showAnswer();
            $("typing").hidden = false;
            $("typed").focus();
        };
        // Checked as it is typed: a complete, correct code goes through by itself (its checksum
        // and session id make a false accept all but impossible); an old error clears on edit.
        $("typed").addEventListener("input", () => {
            $("error").textContent = "";
            const text = $("typed").value;
            const response = parseResponse(text);
            if (response && response.sessionId === sender.sessionId) accept(text);
        });
        $("typed").addEventListener("keydown", (event) => {
            if (event.key === "Enter") {
                event.preventDefault();
                accept($("typed").value);
            }
        });
        document.addEventListener("keydown", (event) => {
            if (!done && event.key === "Escape") finish(() => reject(new Error("User cancelled")), "Cancelled.");
        });
        // A code pasted anywhere on the screen counts, typed or not.
        document.addEventListener("paste", (event) => {
            if (done || event.target === $("typed")) return;
            const text = event.clipboardData?.getData("text") ?? "";
            if (!parseResponse(text)) return;
            showTyping();
            $("typed").value = text;
            accept(text);
        });

        const accept = (text) => {
            const response = parseResponse(text);
            if (!response) {
                $("error").textContent = "Not a NEAR Signer response code. Check for typos and try again.";
                return false;
            }
            if (response.sessionId !== sender.sessionId) {
                $("error").textContent = "This answer is for another request.";
                return false;
            }
            if (response.status !== 0x9000) {
                const message = statusMessage(response.status);
                finish(() => reject(new Error(`NEAR Signer: ${message}`)), `The phone says: ${message}`);
                return true;
            }
            finish(() => resolve(response.result));
            return true;
        };

        $("confirm").addEventListener("click", () => accept($("typed").value));
        $("cancel").addEventListener("click", () => finish(() => reject(new Error("User cancelled")), "Cancelled."));
        // Codes read by the camera page or found in a photo: the first that is an answer goes
        // through `accept`, which also catches an answer to another request.
        const readCodes = (codes) => {
            const text = codes.find((code) => parseResponse(code));
            if (!text) {
                $("error").textContent =
                    codes.length > 0
                        ? "That QR code isn't a NEAR Signer answer."
                        : "No QR code in that photo. Get the whole code in the frame, in focus, and try again.";
                return;
            }
            $("typed").value = text;
            accept(text);
        };
        $("file").addEventListener("change", async () => {
            const [file] = $("file").files;
            $("file").value = ""; // the same photo can be chosen again
            if (!file) return;
            $("error").textContent = "";
            try {
                readCodes(await codesInPhoto(file));
            } catch (error) {
                $("error").textContent = error.message;
            }
        });
        // The camera page's codes arrive through near-connect, which relays what the window posts
        // to its opener (the dapp's page) into this iframe; so does the note that it was closed.
        const onMessage = (event) => {
            if (done || event.source !== window.parent || typeof event.data !== "object" || !event.data) return;
            if (event.data.method === "near-signer-qr:code" && typeof event.data.text === "string") {
                $("error").textContent = "";
                readCodes([event.data.text]);
                if (!done) tell(false, $("error").textContent);
            } else if (event.data.method === "proxy-window:closed") {
                panel = null;
                syncAnswer();
            }
        };
        window.addEventListener("message", onMessage);
        // Brings the camera window up, or to the front when it is up already.
        const openCamera = async () => {
            $("error").textContent = "";
            if (panel) {
                try {
                    await panel.focus();
                } catch {
                    panel = null;
                }
            }
            if (!panel) {
                try {
                    panel = await openCameraWindow(cameraPage);
                } catch (error) {
                    $("error").textContent = error.message;
                }
            }
            syncAnswer();
        };
        $("continue").addEventListener("click", () => {
            showAnswer(live);
            if (live) openCamera();
            else $("file").click();
        });
        $("back").addEventListener("click", showCode);
        $("answer").addEventListener("click", (event) => {
            const id = event.target.closest("button")?.id;
            if (id === "camera" || id === "camera-link") openCamera();
            else if (id === "photo" || id === "photo-link") $("file").click();
            else if (id === "type") showTyping();
        });
    });
}

/// The camera page's URL: the first entry of the manifest's `permissions.allowsOpen`, the one
/// window near-connect lets this executor open. A manifest that names none gets the page next
/// to the executor, which near-connect then refuses to open, with a message that says so: better
/// than a camera button that is silently missing. Null only without a manifest at all.
function cameraPageUrl() {
    const manifest = window.selector.wallet?.manifest;
    const [allowed] = manifest?.permissions?.allowsOpen ?? [];
    if (typeof allowed === "string" && /^https?:\/\//.test(allowed)) return allowed;
    try {
        return new URL("near-signer-qr-camera.html", manifest.executor).href;
    } catch {
        return null;
    }
}

/// Window features for the camera page: a small window over the middle of the dapp's window
/// (near-connect tells the executor where that is), where a sheet would sit. A browser in
/// full-screen mode may open it as a tab instead.
function cameraWindowFeatures() {
    const width = 480;
    const height = 580;
    const host = window.selector;
    const features = ["popup=yes", `width=${width}`, `height=${height}`];
    if ([host.screenX, host.screenY, host.outerWidth, host.outerHeight].every(Number.isFinite)) {
        features.push(`left=${Math.round(host.screenX + Math.max(0, (host.outerWidth - width) / 2))}`);
        features.push(`top=${Math.round(host.screenY + Math.max(0, (host.outerHeight - height) / 2))}`);
    }
    return features.join(",");
}

/// Opens the camera page in a window of its own. Inside near-connect `window.open` is its proxy:
/// the dapp's page opens the window and relays its messages. Rejects, in words for the screen,
/// when the browser blocked the window or the manifest does not allow the URL.
async function openCameraWindow(url) {
    let panel;
    try {
        panel = window.open(url, "_blank", cameraWindowFeatures());
        // The proxy resolves its window id once the dapp has opened the window: null when blocked.
        if (panel && typeof panel.id === "function" && (await panel.id()) == null) panel = null;
    } catch (error) {
        const why = error instanceof Error ? error.message : String(error);
        const detail = /permission denied/i.test(why)
            ? "this wallet's manifest doesn't list the camera page under allowsOpen"
            : why;
        throw new Error(`The camera page can't open (${detail}). Read a photo of the code, or type it.`, {
            cause: error,
        });
    }
    if (!panel) {
        throw new Error(
            "The browser blocked the camera window. Allow pop-ups for this site, or read a photo of the code.",
        );
    }
    return panel;
}

// MARK: - RPC

async function rpc(network, method, params) {
    const response = await fetch(RPC_URLS[network] ?? RPC_URLS.mainnet, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: "near-signer-qr", method, params }),
    });
    const json = await response.json();
    if (json.error) {
        throw new Error(rpcErrorMessage(json.error, network));
    }
    if (json.result?.error) {
        throw new Error(typeof json.result.error === "string" ? json.result.error : JSON.stringify(json.result.error));
    }
    return json.result;
}

/// A sentence for the person instead of the RPC's "Server error": the nested error object names
/// the cause, and the common ones get plain words.
function rpcErrorMessage(error, network) {
    if (typeof error.data === "string") return error.data;
    const names = [];
    let node = error.data;
    while (node && typeof node === "object" && !Array.isArray(node) && Object.keys(node).length === 1) {
        const key = Object.keys(node)[0];
        names.push(key);
        node = node[key];
    }
    const cause = names[names.length - 1];
    const info = node && typeof node === "object" ? node : {};
    switch (cause) {
        case "NotEnoughBalance":
            return `${info.signer_id ?? "The account"} doesn't have enough NEAR for this: balance ${yoctoToNear(info.balance)}, needed ${yoctoToNear(info.cost)}.`;
        case "SignerDoesNotExist":
            return `Account ${info.signer_id ?? ""} doesn't exist on ${network}.`;
        case "InvalidNonce":
            return "The transaction's nonce is stale. Try again.";
        case "Expired":
            return "The transaction expired before it was sent. Try again.";
        case "InvalidAccessKeyError":
            return `This key can't sign that transaction: ${JSON.stringify(info)}.`;
    }
    if (names.length > 0) return `${names.join(" › ")}${Object.keys(info).length ? " " + JSON.stringify(info) : ""}`;
    return error.cause?.name ? `${error.cause.name}: ${error.message}` : (error.message ?? JSON.stringify(error));
}

function yoctoToNear(yocto) {
    if (yocto === undefined || yocto === null) return "?";
    const text = String(yocto).padStart(25, "0");
    const whole = text.slice(0, -24).replace(/^0+(?=\d)/, "");
    const fraction = text.slice(-24, -19).replace(/0+$/, "");
    return `${whole}${fraction ? "." + fraction : ""} NEAR`;
}

async function accessKeyAndBlock(network, accountId, publicKey) {
    const accessKey = await rpc(network, "query", {
        request_type: "view_access_key",
        finality: "final",
        account_id: accountId,
        public_key: publicKey,
    });
    const block = await rpc(network, "block", { finality: "final" });
    return { accessKey, block };
}

async function sendTransaction(network, signedTransaction) {
    return rpc(network, "send_tx", {
        signed_tx_base64: bytesToBase64(signedTransaction),
        wait_until: "EXECUTED_OPTIMISTIC",
    });
}

/// Named accounts that list the key (FastNEAR's index); empty when the lookup fails.
async function accountsForKey(network, publicKey) {
    try {
        const response = await fetch(`${ACCOUNT_APIS[network] ?? ACCOUNT_APIS.mainnet}/v0/public_key/${publicKey}`);
        if (!response.ok) return [];
        return (await response.json()).account_ids ?? [];
    } catch {
        return [];
    }
}

async function hasFullAccessKey(network, accountId, publicKey) {
    const accessKey = await rpc(network, "query", {
        request_type: "view_access_key",
        finality: "final",
        account_id: accountId,
        public_key: publicKey,
    });
    return accessKey.permission === "FullAccess";
}

// MARK: - Sign-in screens

async function promptForPath(current) {
    await window.selector.ui.showIframe();
    return new Promise((resolve, reject) => {
        const $ = showScreen(`
            ${header("Connect NEAR Signer", "Your iPhone keeps the keys. It shows the account's address for you to approve.")}
            <label class="field-label" for="path">Derivation path</label>
            <input id="path" value="${escapeHtml(current)}" autocomplete="off" spellcheck="false">
            <p class="muted" style="margin:6px 0 0">Which of the phone's keys to use. Keep the default unless you know you need another.</p>
            <p class="error" id="error" aria-live="polite"></p>
            <button class="btn" id="next" type="button">Continue</button>
            <button class="btn-text" id="cancel" type="button">Cancel</button>
        `);
        $("next").addEventListener("click", () => {
            try {
                pathBytes($("path").value);
                resolve($("path").value.trim());
            } catch (error) {
                $("error").textContent = error.message;
            }
        });
        $("cancel").addEventListener("click", () => reject(new Error("User cancelled")));
    });
}

async function promptForAccount(network, publicKey, implicitAccountId, named) {
    return new Promise((resolve, reject) => {
        const row = (id, note) =>
            `<button class="account" type="button" data-account="${escapeHtml(id)}"><span class="account-name">${escapeHtml(id)}${note ? `<span class="account-note">${note}</span>` : ""}</span><span class="chevron">›</span></button>`;
        const $ = showScreen(`
            ${header("Choose an account", `Accounts on ${escapeHtml(network)} that hold the phone's key <span class="muted" title="${escapeHtml(publicKey)}">${escapeHtml(shortKey(publicKey))}</span>`)}
            <div class="list" id="list">
                ${named.map((id) => row(id)).join("")}
                ${row(implicitAccountId, "Implicit account of this key")}
            </div>
            <details${named.length === 0 ? " open" : ""}>
                <summary>Use another account</summary>
                <label class="field-label" for="manual">An account that has this key as a full-access key</label>
                <input id="manual" placeholder="${network === "testnet" ? "name.testnet" : "name.near"}" autocomplete="off" spellcheck="false">
                <button class="btn" id="use" type="button">Use this account</button>
            </details>
            <p class="error" id="error" aria-live="polite"></p>
            <button class="btn-text" id="cancel" type="button">Cancel</button>
        `);
        for (const button of document.querySelectorAll("button.account")) {
            button.addEventListener("click", () => resolve(button.dataset.account));
        }
        $("use").addEventListener("click", async () => {
            const accountId = $("manual").value.trim();
            if (!accountId) return;
            $("error").textContent = "";
            try {
                if (!(await hasFullAccessKey(network, accountId, publicKey))) {
                    throw new Error("That key is not a full-access key of this account.");
                }
                resolve(accountId);
            } catch (error) {
                $("error").textContent = /does not exist/.test(error.message)
                    ? `${accountId} doesn't have this key, or doesn't exist on ${network}. Add the key to the account as a full-access key first, or choose another account.`
                    : error.message;
            }
        });
        $("cancel").addEventListener("click", () => reject(new Error("User cancelled")));
    });
}

// MARK: - The wallet

class NearSignerQRWallet {
    async getDerivationPath() {
        return (await window.selector.storage.get(STORAGE_PATH)) || DEFAULT_PATH;
    }

    async getAccounts() {
        const json = await window.selector.storage.get(STORAGE_ACCOUNTS);
        if (!json) return [];
        try {
            return JSON.parse(json);
        } catch {
            return [];
        }
    }

    async ensureAccounts() {
        const accounts = await this.getAccounts();
        if (accounts.length === 0) throw new Error("No account connected");
        return accounts;
    }

    async connect(params) {
        const network = params?.network || "mainnet";
        const path = await promptForPath(await this.getDerivationPath());
        const keyBytes = await requestFromPhone({
            kind: "publicKey",
            path,
            title: "Share the address",
            detail: "Your iPhone shares the account's address with this site.",
        });
        if (keyBytes.length !== 32) throw new Error("The phone did not answer with a public key.");
        const publicKey = `ed25519:${base58Encode(keyBytes)}`;
        const implicitAccountId = Array.from(keyBytes, (b) => b.toString(16).padStart(2, "0")).join("");
        await showLoading("Looking up accounts…", `Accounts on ${network} that hold this key`);
        const named = (await accountsForKey(network, publicKey)).filter((id) => id !== implicitAccountId);
        const accountId = await promptForAccount(network, publicKey, implicitAccountId, named);
        const accounts = [{ accountId, publicKey }];
        await window.selector.storage.set(STORAGE_ACCOUNTS, JSON.stringify(accounts));
        await window.selector.storage.set(STORAGE_PATH, path);
        if (params?.addFunctionCallKey) {
            await this.addFunctionCallKey(params.addFunctionCallKey, accountId, publicKey, path, network);
        }
        return { accounts, path };
    }

    /// Apps ask for a key limited to their contract at sign-in; the phone shows the AddKey.
    async addFunctionCallKey(keyParams, accountId, publicKey, path, network) {
        const { contractId, publicKey: appKey, allowMethods, gasAllowance } = keyParams;
        const methodNames = allowMethods?.anyMethod ? [] : (allowMethods?.methodNames ?? []);
        const { accessKey, block } = await accessKeyAndBlock(network, accountId, publicKey);
        const transaction = buildTransaction({
            signerId: accountId,
            publicKey,
            nonce: BigInt(accessKey.nonce) + 1n,
            receiverId: accountId,
            blockHash: block.header.hash,
            actions: [
                {
                    type: "AddKey",
                    params: {
                        publicKey: appKey,
                        accessKey: {
                            permission: { receiverId: contractId, methodNames, allowance: gasAllowance ?? null },
                        },
                    },
                },
            ],
        });
        const signature = await this.signBytes(
            "transaction",
            transaction,
            path,
            publicKey,
            "Add the app's key",
            "A key limited to this contract, for the app:",
            contractId,
        );
        await sendTransaction(network, withSignature(transaction, signature));
    }

    /// Asks the phone for a signature over `bytes` and checks it.
    async signBytes(kind, bytes, path, publicKey, title, detail, account) {
        const signature = await requestFromPhone({ kind, path, payload: bytes, title, detail, account });
        if (signature.length !== 64) throw new Error("The phone did not answer with a signature.");
        const prefix = kind === "nep413" ? NEP413_PREFIX : kind === "nep366" ? NEP366_PREFIX : new Uint8Array(0);
        await verifySignature(publicKeyBytes(publicKey).subarray(1), await sha256(concat(prefix, bytes)), signature);
        return signature;
    }

    async signIn(params) {
        try {
            const { accounts } = await this.connect(params);
            return accounts;
        } finally {
            window.selector.ui.hideIframe();
        }
    }

    async signInAndSignMessage(params) {
        // A message the phone could not sign is refused before the phone is asked for its key.
        const { message, recipient, nonce } = params.messageParams ?? {};
        const payload = nep413Payload({ message, recipient, nonce: nep413Nonce(nonce) });
        try {
            const { accounts, path } = await this.connect(params);
            const signature = await this.signBytes(
                "nep413",
                payload,
                path,
                accounts[0].publicKey,
                "Sign in",
                "The app's sign-in message, for",
                recipient,
            );
            return accounts.map((account) => ({
                ...account,
                signedMessage: {
                    accountId: account.accountId,
                    publicKey: account.publicKey,
                    signature: bytesToBase64(signature),
                },
            }));
        } finally {
            window.selector.ui.hideIframe();
        }
    }

    async signOut() {
        await window.selector.storage.remove(STORAGE_ACCOUNTS);
        await window.selector.storage.remove(STORAGE_PATH);
        return true;
    }

    async signAndSendTransaction(params) {
        const [account] = await this.ensureAccounts();
        const network = params.network || "mainnet";
        const path = await this.getDerivationPath();
        let { nonce, blockHash } = params;
        if (nonce == null || blockHash == null) {
            await showLoading("Preparing the transaction…");
            const { accessKey, block } = await accessKeyAndBlock(network, account.accountId, account.publicKey);
            nonce ??= BigInt(accessKey.nonce) + 1n;
            blockHash ??= block.header.hash;
        }
        const transaction = buildTransaction({
            signerId: account.accountId,
            publicKey: account.publicKey,
            nonce,
            receiverId: params.receiverId,
            blockHash,
            actions: params.actions,
        });
        try {
            const signature = await this.signBytes(
                "transaction",
                transaction,
                path,
                account.publicKey,
                "Sign the transaction",
                "To",
                params.receiverId,
            );
            await showLoading("Sending the transaction…");
            return await sendTransaction(network, withSignature(transaction, signature));
        } finally {
            window.selector.ui.hideIframe();
        }
    }

    async signAndSendTransactions(params) {
        const [account] = await this.ensureAccounts();
        const network = params.network || "mainnet";
        const { accessKey, block } = await accessKeyAndBlock(network, account.accountId, account.publicKey);
        let nonce = BigInt(accessKey.nonce);
        const results = [];
        for (const transaction of params.transactions) {
            nonce += 1n;
            results.push(
                await this.signAndSendTransaction({
                    network,
                    receiverId: transaction.receiverId,
                    actions: transaction.actions,
                    nonce,
                    blockHash: block.header.hash,
                }),
            );
        }
        return results;
    }

    async signDelegateActions(params) {
        const [account] = await this.ensureAccounts();
        const network = params.network || "mainnet";
        const path = await this.getDerivationPath();
        const { accessKey, block } = await accessKeyAndBlock(network, account.accountId, account.publicKey);
        let nonce = BigInt(accessKey.nonce);
        const maxBlockHeight = BigInt(block.header.height) + MAX_BLOCK_HEIGHT_INCREMENT;
        const signedDelegateActions = [];
        try {
            for (const { receiverId, actions } of params.delegateActions) {
                nonce += 1n;
                const delegate = buildDelegateAction({
                    senderId: account.accountId,
                    receiverId,
                    actions,
                    nonce,
                    maxBlockHeight,
                    publicKey: account.publicKey,
                });
                const signature = await this.signBytes(
                    "nep366",
                    delegate,
                    path,
                    account.publicKey,
                    "Sign the transaction",
                    "Relayed by the app, which pays the fee. To",
                    receiverId,
                );
                signedDelegateActions.push(bytesToBase64(withSignature(delegate, signature)));
            }
        } finally {
            window.selector.ui.hideIframe();
        }
        return { signedDelegateActions };
    }

    async signMessage(params) {
        const [account] = await this.ensureAccounts();
        const path = await this.getDerivationPath();
        const payload = nep413Payload({
            message: params.message,
            recipient: params.recipient,
            nonce: nep413Nonce(params.nonce),
            callbackUrl: params.callbackUrl,
        });
        try {
            const signature = await this.signBytes(
                "nep413",
                payload,
                path,
                account.publicKey,
                "Sign the message",
                "For",
                params.recipient,
            );
            return { accountId: account.accountId, publicKey: account.publicKey, signature: bytesToBase64(signature) };
        } finally {
            window.selector.ui.hideIframe();
        }
    }
}

window.selector.ready(new NearSignerQRWallet());

/// Raw DEFLATE of a payload worth compressing (64 bytes or more, and smaller once compressed),
/// or undefined: contract code shrinks about three times, a transfer not at all. Browsers without
/// CompressionStream send the payload as it is.
async function deflateIfSmaller(payload) {
    if (payload.length < 64 || typeof CompressionStream === "undefined") return undefined;
    try {
        const stream = new Blob([payload]).stream().pipeThrough(new CompressionStream("deflate-raw"));
        const deflated = new Uint8Array(await new Response(stream).arrayBuffer());
        // Four bytes of the message hold the inflated length.
        return deflated.length + 4 < payload.length ? deflated : undefined;
    } catch {
        return undefined;
    }
}
