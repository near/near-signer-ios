// The camera page: reads the phone's answer with the computer's camera for the near-connect
// executor, in a window of its own. near-connect runs the executor in a sandboxed iframe with an
// opaque origin, and a browser gives such a document no camera (Chrome: "Invalid security
// origin"), whatever the iframe's `allow` says. What near-connect does let an executor do is open
// a window on a URL its manifest lists under `permissions.allowsOpen`, and it relays every message
// that window posts to its opener into the executor's iframe (after checking the message's origin
// against that URL). So the executor opens this page, served next to it, and the page does the
// reading: it posts each NEAR Signer answer code it sees to the opener, shows the executor's
// verdict, and closes once the executor is done with the request.
//
// Messages, both as plain objects:
//   page → executor   { method: "near-signer-qr:code", text }
//   executor → page   { method: "near-signer-qr:result", done, message }   done: close this window
//
// On the screen: a viewfinder with the live picture (mirrored for a camera facing the user), the
// outline of a code the moment it is read, a status line that always says what is happening, a
// check mark and a ring when the answer went through, a shake when a code was not it, "Try again"
// when the camera could not start, and "Switch camera" when there is more than one.
//
// scripts/build-optical-executor.mjs inlines this with jsQR, optical.mjs (parseResponse) and
// scan.mjs into near-signer-qr-camera.html, so the page is one file to serve, like the executor.

const $ = (id) => document.getElementById(id);
const CLOSE_DELAY = 1300; // the check mark is seen before the window goes

let stream = null;
let stopScan = null;
let finished = false;
let cameras = []; // the video inputs, once known
let cameraIndex = -1;
let outlineTimer = null;

function say(text, kind = "") {
    $("status").textContent = text;
    $("status").className = `status ${kind}`;
}

function stopCamera() {
    stopScan?.();
    stopScan = null;
    if (stream) for (const track of stream.getTracks()) track.stop();
    stream = null;
    document.body.classList.remove("scanning");
}

/// Draws the code's outline over the picture, in the video's own pixels mapped onto the frame
/// (the video fills the frame as `object-fit: cover` does: scaled to cover, centered, cropped).
function outline(corners, color) {
    const canvas = $("overlay");
    const video = $("video");
    const box = canvas.getBoundingClientRect();
    const ratio = window.devicePixelRatio || 1;
    canvas.width = Math.round(box.width * ratio);
    canvas.height = Math.round(box.height * ratio);
    const context = canvas.getContext("2d");
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, box.width, box.height);
    clearTimeout(outlineTimer);
    if (!corners || !video.videoWidth) return;
    const scale = Math.max(box.width / video.videoWidth, box.height / video.videoHeight);
    const dx = (box.width - video.videoWidth * scale) / 2;
    const dy = (box.height - video.videoHeight * scale) / 2;
    context.beginPath();
    corners.forEach(({ x, y }, i) => context[i === 0 ? "moveTo" : "lineTo"](x * scale + dx, y * scale + dy));
    context.closePath();
    context.lineWidth = 4;
    context.lineJoin = "round";
    context.strokeStyle = color;
    context.shadowColor = color;
    context.shadowBlur = 14;
    context.stroke();
    outlineTimer = setTimeout(() => outline(null), 700);
}

/// The answer went through: the executor is done with the request, so is this window.
function celebrate(message) {
    finished = true;
    stopScan?.();
    stopScan = null;
    document.body.classList.remove("scanning");
    document.body.classList.add("done");
    outline(null);
    say(message || "Answer received.", "ok");
    $("hint").textContent = "Back to the wallet.";
    $("switch").hidden = true;
    setTimeout(() => {
        window.close();
        // A tab the browser would not close: say so, instead of a frozen success screen.
        setTimeout(() => {
            if (!window.closed) say("Done. You can close this window.", "ok");
        }, 300);
    }, CLOSE_DELAY);
}

/// A code that was read but not accepted: the frame shakes, the status says why.
function turnDown(message) {
    const frame = $("frame");
    frame.classList.remove("shake");
    void frame.offsetWidth; // restarts the animation
    frame.classList.add("shake");
    say(message, "bad");
}

/// Opens the camera: `index` picks one of the known inputs, otherwise scan.mjs chooses the facing
/// side. A camera that does not say it faces away is shown mirrored, as a mirror is what people
/// expect when they line something up with it; the reader sees the frames as they are.
async function startCamera(index = -1) {
    stopCamera();
    $("retry").hidden = true;
    $("foot").hidden = true;
    outline(null);
    say("Starting the camera…");
    try {
        stream =
            index >= 0 && cameras[index]
                ? await navigator.mediaDevices.getUserMedia({ video: { deviceId: { exact: cameras[index].deviceId } } })
                : await openCamera();
    } catch (error) {
        say(error.message, "bad");
        $("retry").hidden = false;
        $("foot").hidden = false;
        if (error.cause?.name === "NotAllowedError") {
            $("hint").textContent = "Allow the camera for this site in the browser's address bar, then try again.";
        }
        return;
    }
    const video = $("video");
    video.srcObject = stream;
    await video.play();
    const settings = stream.getVideoTracks()[0]?.getSettings?.() ?? {};
    $("frame").classList.toggle("mirror", settings.facingMode !== "environment");
    cameraIndex = cameras.findIndex((camera) => camera.deviceId && camera.deviceId === settings.deviceId);
    try {
        // Labels and ids come once a camera was allowed; more than one input gets the switch.
        cameras = (await navigator.mediaDevices.enumerateDevices()).filter((device) => device.kind === "videoinput");
        $("switch").hidden = cameras.length < 2;
    } catch {
        $("switch").hidden = true;
    }
    say("Looking for the code…");
    document.body.classList.add("scanning");

    // Every answer once: the executor says whether it was the one; the same code again would only
    // repeat the verdict. A code that is no answer is turned down once too, not on every frame it
    // stays in view.
    const sent = new Set();
    let lastStranger = null;
    stopScan = scanVideo(
        video,
        (texts, codes) => {
            if (finished) return;
            const hit = codes.find((code) => parseResponse(code.text));
            if (!hit) {
                outline(codes[0]?.corners, "#ff6b6b");
                if (codes[0]?.text !== lastStranger) turnDown("That QR code isn't a NEAR Signer answer.");
                lastStranger = codes[0]?.text ?? null;
                return;
            }
            lastStranger = null;
            outline(hit.corners, "#00d4aa");
            if (sent.has(hit.text)) return;
            sent.add(hit.text);
            say("Checking…");
            window.opener.postMessage({ method: "near-signer-qr:code", text: hit.text }, "*");
        },
        120,
    );
}

function main() {
    $("close").addEventListener("click", () => window.close());
    $("retry").addEventListener("click", () => startCamera(cameraIndex));
    $("switch").addEventListener("click", () => startCamera((cameraIndex + 1) % Math.max(1, cameras.length)));
    document.addEventListener("keydown", (event) => {
        if (event.key === "Escape") window.close();
    });
    window.addEventListener("pagehide", stopCamera);
    if (!window.opener) {
        say(
            "Open this page from the NEAR Signer window in your wallet: it reads the phone's answer for that window.",
            "bad",
        );
        return;
    }
    window.addEventListener("message", (event) => {
        if (event.source !== window.opener || event.data?.method !== "near-signer-qr:result") return;
        if (event.data.done) celebrate(event.data.message);
        else turnDown(event.data.message || "That code didn't go through. Try again.");
    });
    startCamera();
}

main();
