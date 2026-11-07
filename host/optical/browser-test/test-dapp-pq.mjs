// See lib.mjs for how to run these. This one takes the simulator's ML-DSA-65 key through the
// dapp on testnet: the Quantum-safe account type on the connect screen, at the default path
// 44'/397'/0'/0'/1', makes every request name the ML-DSA-65 key (instruction bit 0x40, which the
// simulator follows, as the phone does). The key's universal account ("0u…") shows up in the
// account list, a transfer from it asks for a deposit while the account does not exist, the
// deposit comes from thi3.testnet (the simulator's ed25519 key at the same path is a full-access
// key there; its requests carry no flag), the next transfer activates the account first
// ("Activate the account", one more request from the phone) and then goes through. Run again, the
// account is active already and only the transfer happens; each run moves 0.1 NEAR within the
// account.
import { execFileSync } from "node:child_process";
import { SIM, collectRequest, confirmIfStill, launch, shot, signWithSim, typeAnswer } from "./lib.mjs";
import { parseFrame, parseResponse } from "../optical.mjs";
import { accountIdForPublicKey, isUniversalAccountId, publicKeyString } from "../borsh.mjs";

const PATH = "44'/397'/0'/0'/1'";
const RPC = "https://test.rpc.fastnear.com";
const FUNDER = "thi3.testnet";
const FUNDING = "500000000000000000000000"; // 0.5 NEAR: storage, the activation and the transfer

function check(condition, message) {
    if (!condition) throw new Error(`FAILED: ${message}`);
}

async function rpc(method, params) {
    const response = await fetch(RPC, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: "pq-test", method, params }),
    });
    const json = await response.json();
    if (json.error) throw new Error(json.error.data ?? JSON.stringify(json.error));
    return json.result;
}

/// "missing", "uninitialized" or "active", as the executor sees it.
async function accountState(accountId) {
    try {
        const account = await rpc("query", { request_type: "view_account", finality: "final", account_id: accountId });
        return account.state === "uninitialized" || account.bootstrap_nonce != null ? "uninitialized" : "active";
    } catch (error) {
        if (/does not exist/.test(error.message)) return "missing";
        throw error;
    }
}

async function waitForState(accountId, wanted, timeoutMs = 60000) {
    const started = Date.now();
    while (Date.now() - started < timeoutMs) {
        const state = await accountState(accountId);
        if (state === wanted) return;
        await new Promise((resolve) => setTimeout(resolve, 2000));
    }
    throw new Error(`${accountId} is not ${wanted} after ${timeoutMs} ms`);
}

// 0. The simulator's ML-DSA-65 key at the path, from the phrase's ML-DSA-65 tree.
let simKey = "";
try {
    simKey = execFileSync(SIM, ["pubkey", "--key-type", "ml-dsa-65", "--path", `m/${PATH}`], { stdio: "pipe" })
        .toString()
        .trim();
} catch (error) {
    console.error("near-signer-sim pubkey failed:", error.stderr?.toString().trim().slice(-300));
    process.exit(2);
}
if (!/^ml-dsa-65:/m.test(simKey)) {
    console.error(
        `near-signer-sim does not print an ML-DSA-65 key with --key-type ml-dsa-65; it printed: ${simKey.slice(-120)}`,
    );
    process.exit(2);
}

const { browser, page, logs } = await launch({ width: 1100, height: 950 });
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

/// Whether a request's message names the ML-DSA-65 key: its instruction's bit 0x40.
const asksForMlDsa65 = (request) => (request.message[0] & 0x40) !== 0;

/// Opens the wallet list, picks NEAR Signer, chooses the account type (`keyType`, "ed25519" or
/// "ml-dsa-65") on the connect screen, which leaves the path as it is and sets the flag the
/// simulator then follows, answers the public key request with the simulator and returns the
/// executor's frame, the rows of its account list and the answer.
async function connect(keyType) {
    await page.click("#connect");
    await page.waitForTimeout(1500);
    await page.locator('.connect-item[data-type="near-signer-qr"]').first().click();
    await page.waitForTimeout(2000);
    const frame = exec();
    await frame.click(`label[for="type-${keyType}"]`);
    const path = await frame.inputValue("#path");
    check(path === PATH, `the ${keyType} choice set the path to ${path}, not ${PATH}`);
    await frame.click("#next");
    await page.waitForTimeout(800);
    const request = await collectRequest(frame, { timeoutMs: 30000 });
    check(
        asksForMlDsa65(request) === (keyType === "ml-dsa-65"),
        `the ${keyType} key request starts with ${request.message[0].toString(16)}`,
    );
    const answer = await signWithSim(request.frames);
    await typeAnswer(frame, answer);
    await page.waitForTimeout(400);
    await confirmIfStill(frame);
    await frame.waitForSelector("#list", { timeout: 30000 });
    const rows = await frame.$$eval("#list .account", (buttons) =>
        buttons.map((button) => ({
            id: button.dataset.account,
            note: button.querySelector(".account-note")?.textContent ?? "",
        })),
    );
    return { frame, rows, answer };
}

async function chooseAccount(frame, rows, accountId) {
    if (rows.some((row) => row.id === accountId)) {
        await frame.click(`#list .account[data-account="${accountId}"]`);
    } else {
        // Not in FastNEAR's index right now: the manual way.
        if (!(await frame.$("details[open]"))) await frame.click("summary");
        await frame.fill("#manual", accountId);
        await frame.click("#use");
    }
    await page.waitForFunction(
        (id) => document.getElementById("log").textContent.includes(`Signed in as ${id}`),
        accountId,
        {
            timeout: 30000,
        },
    );
}

async function disconnect() {
    await page.click("#disconnect");
    await page.waitForTimeout(1200);
}

/// Waits for the executor to show a request (a code of a new session) or for the dapp's log to
/// end the flow; returns `{ title, sessionId }` or `{ done, log }`.
async function nextRequestOrEnd(previousSessionId, timeoutMs = 90000) {
    const started = Date.now();
    while (Date.now() - started < timeoutMs) {
        const log = await dappLog();
        if (/^(Sent:|Error:)/.test(log)) return { done: true, log };
        const frame = exec();
        if (frame) {
            const visible = await frame.isVisible("#code").catch(() => false);
            if (visible) {
                // A code of the session just answered may still be up for a moment: the session
                // id of the frames tells a new request from it.
                const title = (await frame.textContent(".title").catch(() => "")).trim();
                const request = await collectRequest(frame, { timeoutMs: 30000 });
                const sessionId = parseFrame(request.frames[0]).sessionId;
                if (sessionId !== previousSessionId) return { title, frame, request, sessionId };
            }
        }
        await new Promise((resolve) => setTimeout(resolve, 500));
    }
    throw new Error("the executor showed no new request and the dapp did not finish");
}

/// Answers the request `next` holds with the simulator's key at the request's path.
async function answer(next) {
    const text = await signWithSim(next.request.frames);
    await typeAnswer(next.frame, text);
    await page.waitForTimeout(400);
    await confirmIfStill(next.frame);
}

// 1. Connect with the ML-DSA-65 key: the account list offers its universal account.
let { frame, rows, answer: keyAnswer } = await connect("ml-dsa-65");
console.log("account list:", rows);
const keyBytes = parseResponse(keyAnswer).result;
check(keyBytes.length === 1952, `the simulator's key is ${keyBytes.length} bytes, not 1952`);
const publicKey = publicKeyString(keyBytes);
check(publicKey === simKey, "the key the dapp got is not the one near-signer-sim pubkey --key-type ml-dsa-65 prints");
const zeroU = accountIdForPublicKey(publicKey);
const own = rows.find((row) => /Quantum-safe/.test(row.note));
check(own, "the list has no quantum-safe account row");
check(own.id === zeroU, `the row's id ${own.id} is not the key's universal account ${zeroU}`);
check(isUniversalAccountId(zeroU), `${zeroU} is not a universal account id`);
console.log("universal account:", zeroU);
await shot(page, "pq-accounts");
await chooseAccount(frame, rows, zeroU);
console.log("dapp log:", (await dappLog()).split("\n")[0]);

// 2. The account on testnet: a transfer from one that does not exist asks for a deposit first.
let state = await accountState(zeroU);
console.log("account state:", state);
if (state === "missing") {
    await page.click("#send");
    frame = await waitForExecutor("#account");
    const title = (await frame.textContent(".title")).trim();
    const shown = (await frame.inputValue("#account")).trim();
    console.log("deposit screen:", title, "|", shown);
    check(title === "Fund the account first", `unexpected title ${title}`);
    check(shown === zeroU, "the deposit screen shows another id");
    await shot(page, "pq-fund-first");
    await frame.click("#cancel");
    await page.waitForFunction(() => /^Error:/.test(document.getElementById("log").textContent), null, {
        timeout: 10000,
    });
    const log = await dappLog();
    console.log("after cancel:", log.slice(0, 160));
    check(log.includes(`Send NEAR to ${zeroU} first`), "the cancel message does not name the deposit");

    // The deposit, from thi3.testnet with the ed25519 key.
    await disconnect();
    ({ frame, rows } = await connect("ed25519"));
    await chooseAccount(frame, rows, FUNDER);
    await page.evaluate(
        ({ receiverId, deposit }) => {
            window.__fundResult = null;
            window.nearConnector
                .wallet()
                .then((wallet) =>
                    wallet.signAndSendTransaction({
                        receiverId,
                        actions: [{ type: "Transfer", params: { deposit } }],
                    }),
                )
                .then(
                    (outcome) => {
                        window.__fundResult = { ok: true, hash: outcome?.transaction?.hash ?? null };
                    },
                    (error) => {
                        window.__fundResult = { ok: false, error: error.message };
                    },
                );
        },
        { receiverId: zeroU, deposit: FUNDING },
    );
    const funding = await nextRequestOrEnd(null);
    check(!funding.done, `no transfer request: ${funding.log}`);
    console.log("funding request:", funding.title);
    check(!asksForMlDsa65(funding.request), "the classic account's transfer asked for the ML-DSA-65 key");
    await answer(funding);
    await page.waitForFunction(() => window.__fundResult, null, { timeout: 90000 });
    const funded = await page.evaluate(() => window.__fundResult);
    console.log("funding:", funded);
    check(funded.ok, `the deposit failed: ${funded.error}`);
    await waitForState(zeroU, "uninitialized");
    await disconnect();
    ({ frame, rows } = await connect("ml-dsa-65"));
    await chooseAccount(frame, rows, zeroU);
    state = await accountState(zeroU);
    console.log("account state now:", state);
}

// 3. A transfer to itself: an uninitialized account activates first (one request), then signs
// the transfer (another); an active one just signs the transfer.
const expected =
    state === "uninitialized" ? ["Activate the account", "Sign the transaction"] : ["Sign the transaction"];
await page.click("#send");
const titles = [];
let sessionId = null;
for (;;) {
    const next = await nextRequestOrEnd(sessionId);
    if (next.done) {
        console.log("dapp log:", next.log.slice(0, 300));
        check(/^Sent:/.test(next.log), `the transfer did not go through: ${next.log.slice(0, 300)}`);
        break;
    }
    sessionId = next.sessionId;
    titles.push(next.title);
    check(asksForMlDsa65(next.request), `"${next.title}" did not ask for the ML-DSA-65 key`);
    console.log("request:", next.title, "|", (await next.frame.textContent(".subtitle")).replace(/\s+/g, " ").trim());
    if (next.title === "Activate the account") await shot(page, "pq-activate");
    await answer(next);
    check(titles.length <= 3, "too many requests");
}
console.log("requests:", titles);
check(JSON.stringify(titles) === JSON.stringify(expected), `expected ${expected.join(", ")}`);
await shot(page, "pq-sent");

// 4. The chain agrees: the account is active and the ML-DSA-65 key is its full-access key.
check((await accountState(zeroU)) === "active", "the account is not active");
const accessKey = await rpc("query", {
    request_type: "view_access_key",
    finality: "final",
    account_id: zeroU,
    public_key: publicKey,
});
console.log("access key:", accessKey.permission, "nonce", accessKey.nonce);
check(accessKey.permission === "FullAccess", "the key is not a full-access key");
console.log(
    "console:",
    logs
        .filter((l) => !/favicon/.test(l))
        .join(" || ")
        .slice(0, 600),
);
await browser.close();
console.log("OK");
