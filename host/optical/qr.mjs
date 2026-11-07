// QR codes for the camera transfer, drawn with qrcode-generator (vendor/, MIT): the module
// matrix for a canvas, and lines of block characters for a terminal.
//
// In Node the vendored file is loaded as CommonJS. In a browser it is a classic script (it sets
// the global `qrcode`), so load it with a <script> tag before this module.

const qrcodeFactory = globalThis.qrcode ?? (await import("./vendor/qrcode-generator.js")).default;

const ALPHANUMERIC = /^[0-9A-Z $%*+\-./:]*$/;

/// The modules of the smallest QR code that holds `text`. Frame and response texts fit the
/// alphanumeric mode, which packs 5.5 bits per character instead of 8.
export function qrMatrix(text, { ecLevel = "L" } = {}) {
    const qr = qrcodeFactory(0, ecLevel);
    qr.addData(text, ALPHANUMERIC.test(text) ? "Alphanumeric" : "Byte");
    qr.make();
    const size = qr.getModuleCount();
    return { size, get: (x, y) => x >= 0 && y >= 0 && x < size && y < size && qr.isDark(y, x) };
}

/// The code as lines of text, two module rows per line, with a quiet zone. Terminals are usually
/// light text on a dark background, so by default light modules are the drawn blocks and dark
/// modules are the background, which gives a normal dark-on-light code; `invert` is for dark
/// text on a light background.
export function renderTerminal(matrix, { invert = false, quietZone = 2 } = {}) {
    const light = (x, y) => matrix.get(x, y) === invert;
    const lines = [];
    for (let y = -quietZone; y < matrix.size + quietZone; y += 2) {
        let line = "";
        for (let x = -quietZone; x < matrix.size + quietZone; x++) {
            const top = light(x, y);
            const bottom = light(x, y + 1);
            line += top ? (bottom ? "█" : "▀") : bottom ? "▄" : " ";
        }
        lines.push(line);
    }
    return lines;
}

/// Bytes per code, largest first: the same ladder as the terminal sender.
export const FRAGMENT_SIZES = [1200, 1000, 800, 650, 500, 400, 300, 220, 160, 120, 80, 50];

/// Modules across a code holding a frame of `fragmentSize` bytes (header 19 bytes, base45 1.5
/// characters a byte, `NS1:` prefix).
export function frameModules(fragmentSize) {
    return qrMatrix("NS1:" + "A".repeat(Math.ceil((19 + fragmentSize) * 1.5))).size;
}

/// The most bytes per code whose code, with its quiet zone, fits `availablePx` at `pxPerModule`
/// pixels a module: a phone camera reads about 4 CSS pixels a module (8 device pixels on a
/// 2× screen) from a normal distance, so the width of the screen sets the speed of a transfer.
export function fittingFragmentSize(availablePx, { pxPerModule = 4, quietZone = 8 } = {}) {
    return (
        FRAGMENT_SIZES.find((size) => (frameModules(size) + quietZone) * pxPerModule <= availablePx) ??
        FRAGMENT_SIZES.at(-1)
    );
}

/// The width in pixels to draw a code of `modules` at: the camera's density with a little room,
/// never below 160 px, never beyond what is available. A small request gets a small code.
export function codeWidth(modules, availablePx, { pxPerModule = 4, quietZone = 8 } = {}) {
    return Math.min(availablePx, Math.max(160, Math.round((modules + quietZone) * pxPerModule * 1.1)));
}

/// Draws the code on a canvas 2D context, dark on white, with a quiet zone.
export function drawCanvas(context, matrix, { size, quietZone = 4 } = {}) {
    const modules = matrix.size + 2 * quietZone;
    const scale = Math.floor(size / modules) || 1;
    const offset = Math.floor((size - scale * modules) / 2);
    context.fillStyle = "#ffffff";
    context.fillRect(0, 0, size, size);
    context.fillStyle = "#000000";
    for (let y = 0; y < matrix.size; y++) {
        for (let x = 0; x < matrix.size; x++) {
            if (matrix.get(x, y)) {
                context.fillRect(offset + (x + quietZone) * scale, offset + (y + quietZone) * scale, scale, scale);
            }
        }
    }
}
