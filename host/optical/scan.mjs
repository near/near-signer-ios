// Reading the phone's answer on the computer. The phone shows one QR code; this reads it from a
// live camera, or from a photo: a file input with `capture` opens the camera on a phone or tablet,
// so the photo is taken in place, and needs no camera permission (near-connect's sandbox grants
// none). Browser only. The browser's BarcodeDetector decodes where it reads QR codes (Chrome,
// Edge, Android); elsewhere jsQR does (vendor/jsQR.js, loaded as a script before this module), so
// Safari and Firefox read codes too. Shared by index.html and the near-connect executor.

/// A phone or tablet runs this: a photo taken in place beats a live stream there.
export function isTouchDevice() {
    return typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;
}

let detectorPromise = null;

/// The decoder: from an image source (a video, a canvas, an ImageBitmap) to the QR codes in it,
/// each `{ text, corners }`, the corners four `{ x, y }` in the source's pixels (top left, top
/// right, bottom right, bottom left) or null when the decoder gives none. `thorough` tries more
/// sizes, for a photo. Resolved once per page; null when the browser has neither BarcodeDetector
/// nor jsQR.
export function codeDetector() {
    detectorPromise ??= (async () => {
        try {
            const Detector = globalThis.BarcodeDetector;
            if (typeof Detector === "function" && (await Detector.getSupportedFormats()).includes("qr_code")) {
                const detector = new Detector({ formats: ["qr_code"] });
                return async (source) =>
                    (await detector.detect(source)).map((code) => ({
                        text: code.rawValue,
                        corners:
                            code.cornerPoints?.length === 4 ? code.cornerPoints.map(({ x, y }) => ({ x, y })) : null,
                    }));
            }
        } catch {
            // No usable BarcodeDetector; jsQR below.
        }
        return typeof globalThis.jsQR === "function"
            ? async (source, options) => decodeWithJsQR(source, options)
            : null;
    })();
    return detectorPromise;
}

/// jsQR over the pixels of `source`, scaled to at most `side` pixels on the long side, one size
/// after another until a code reads. A 12-megapixel photo takes seconds at full size and reads as
/// well around 1 000; a code small in the frame wants more; a video frame gets one quick pass.
function decodeWithJsQR(source, { thorough = false } = {}) {
    const width = source.videoWidth ?? source.naturalWidth ?? source.width;
    const height = source.videoHeight ?? source.naturalHeight ?? source.height;
    if (!width || !height) return [];
    const sides = thorough ? [1000, 1600, 640] : [640];
    const scales = [...new Set(sides.map((side) => Math.min(1, side / Math.max(width, height))))];
    const canvas = document.createElement("canvas");
    const context = canvas.getContext("2d", { willReadFrequently: true });
    for (const scale of scales) {
        canvas.width = Math.round(width * scale);
        canvas.height = Math.round(height * scale);
        context.drawImage(source, 0, 0, canvas.width, canvas.height);
        const image = context.getImageData(0, 0, canvas.width, canvas.height);
        const code = globalThis.jsQR(image.data, image.width, image.height, { inversionAttempts: "attemptBoth" });
        if (code?.data) {
            const { topLeftCorner, topRightCorner, bottomRightCorner, bottomLeftCorner } = code.location ?? {};
            const corners = [topLeftCorner, topRightCorner, bottomRightCorner, bottomLeftCorner];
            return [
                {
                    text: code.data,
                    corners: corners.every(Boolean)
                        ? corners.map(({ x, y }) => ({ x: x / scale, y: y / scale }))
                        : null,
                },
            ];
        }
    }
    return [];
}

/// The texts of the QR codes in a photo (a File or Blob from a file input).
export async function codesInPhoto(file) {
    const detect = await codeDetector();
    if (!detect) throw new Error("This browser can't read QR codes from a photo. Type the code instead.");
    const bitmap = await createImageBitmap(file);
    try {
        return (await detect(bitmap, { thorough: true })).map((code) => code.text);
    } finally {
        bitmap.close();
    }
}

/// Opens the camera: the one facing away on a phone or tablet (the NEAR Signer phone is held in
/// front of it), the one facing the user on a computer (the phone is held up to the screen). The
/// error's message is for the screen: no camera, permission refused, or a host that gives the page
/// no camera, as near-connect's sandbox does; a photo or typing is the way then.
export async function openCamera() {
    if (!navigator.mediaDevices?.getUserMedia) {
        throw new Error("This browser gives the page no camera. Read a photo of the code, or type it.");
    }
    try {
        return await navigator.mediaDevices.getUserMedia({
            video: { facingMode: isTouchDevice() ? "environment" : "user" },
        });
    } catch (error) {
        const why =
            error.name === "NotAllowedError"
                ? "the camera isn't allowed here"
                : error.name === "NotFoundError"
                  ? "there is no camera"
                  : error.message;
        throw new Error(`Camera: ${why}. Read a photo of the code, or type it.`, { cause: error });
    }
}

/// Reads the codes in a playing video every `every` ms, calling `onCodes(texts, codes)` with each
/// non-empty batch (the texts, and the codes with their corners), until the returned function is
/// called.
export function scanVideo(video, onCodes, every = 150) {
    let stopped = false;
    (async () => {
        const detect = await codeDetector();
        while (!stopped && detect) {
            try {
                if (video.readyState >= 2) {
                    const codes = await detect(video, { thorough: false });
                    if (codes.length > 0 && !stopped)
                        onCodes(
                            codes.map((code) => code.text),
                            codes,
                        );
                }
            } catch {
                // A frame that could not be read; the next one will do.
            }
            await new Promise((resolve) => setTimeout(resolve, every));
        }
    })();
    return () => {
        stopped = true;
    };
}
