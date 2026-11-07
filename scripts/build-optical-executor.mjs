#!/usr/bin/env node
// Bundles the near-connect side of the camera transfer into two files in host/optical/:
//
//   near-signer-qr-executor.js    the executor: near-connect loads it from a single URL into a
//                                 sandboxed iframe, where modules can't import each other
//   near-signer-qr-camera.html    the camera page the executor opens to read the phone's answer,
//                                 served next to the executor (the manifest's allowsOpen)
//
// Both outputs are committed; CI rebuilds them and fails if they differ, so run this after changing
// any of their parts:
//
//   host/optical/vendor/qrcode-generator.js   QR generator (MIT), unchanged
//   host/optical/vendor/jsQR.js               QR reader (Apache-2.0), unchanged
//   host/optical/optical.mjs                  the codec
//   host/optical/borsh.mjs                    transactions, delegate actions, NEP-413 payloads
//   host/optical/qr.mjs                       drawing
//   host/optical/scan.mjs                     reading the phone's answer with a camera or from a photo
//   host/optical/executor/main.js             the executor itself
//   host/optical/executor/camera.html, camera.js   the camera page

import fs from "node:fs";

const root = new URL("../host/optical/", import.meta.url);
const read = (name) => fs.readFileSync(new URL(name, root), "utf8");

/// A module's code as a plain script: no imports (every part is in scope), no exports.
function plain(name) {
    const source = read(name)
        .replace(/^import [^;]*;\n/gm, "")
        .replace(/^export (const|let|function|async function|class) /gm, "$1 ")
        .replace(/^export \{[^}]*\};\n/gm, "");
    const leftover = source.match(/^(import|export) /m);
    if (leftover) throw new Error(`${name}: could not strip "${leftover[0].trim()}"`);
    return `// ---- ${name}\n${source}`;
}

function write(name, content) {
    fs.writeFileSync(new URL(name, root), content);
    console.log(`host/optical/${name}: ${content.length} bytes`);
}

const credits = [
    "Contains qrcode-generator (MIT, Kazuhiko Arase; see",
    "host/optical/vendor/LICENSE-qrcode-generator) and jsQR (Apache-2.0, Cosmo Wolfe; see",
    "host/optical/vendor/LICENSE-jsQR).",
];

// The executor.
const qr = plain("qr.mjs").replace(
    /^const qrcodeFactory = .*$/m,
    "const qrcodeFactory = qrcode; // the vendored generator, bundled above",
);
if (!qr.includes("const qrcodeFactory = qrcode;")) throw new Error("qr.mjs: the generator line changed");

write(
    "near-signer-qr-executor.js",
    [
        "// near-signer-qr-executor.js: the NEAR Signer camera executor for near-connect.",
        "// Built by scripts/build-optical-executor.mjs from host/optical/; do not edit. See",
        "// host/optical/executor/main.js for the manifest and the executor, and README.md",
        `// "Camera transfer" for the format. ${credits[0]}`,
        `// ${credits[1]}`,
        `// ${credits[2]}`,
        "(() => {",
        "// ---- vendor/qrcode-generator.js",
        read("vendor/qrcode-generator.js"),
        "// ---- vendor/jsQR.js",
        read("vendor/jsQR.js"),
        plain("optical.mjs"),
        plain("borsh.mjs"),
        qr,
        plain("scan.mjs"),
        plain("executor/main.js"),
        "})();",
        "",
    ].join("\n"),
);

// The camera page: the markup with its one script filled in.
const marker = "<script>/* BUILD: vendor/jsQR.js optical.mjs scan.mjs executor/camera.js */</script>";
const page = read("executor/camera.html");
if (!page.includes(marker)) throw new Error("executor/camera.html: the BUILD script marker is missing");
const script = [
    "// Built by scripts/build-optical-executor.mjs from host/optical/; do not edit. See",
    `// host/optical/executor/camera.js. Contains jsQR (Apache-2.0, Cosmo Wolfe; see`,
    "// host/optical/vendor/LICENSE-jsQR).",
    "(() => {",
    "// ---- vendor/jsQR.js",
    read("vendor/jsQR.js"),
    plain("optical.mjs"),
    plain("scan.mjs"),
    plain("executor/camera.js"),
    "})();",
].join("\n");
// Inside a <script>, these would end it or start a comment for the HTML parser.
for (const bad of ["</script", "<!--"]) {
    if (script.toLowerCase().includes(bad)) throw new Error(`the camera page's script contains "${bad}"`);
}
write(
    "near-signer-qr-camera.html",
    page.replace(/^<!-- The camera page's markup[^]*?-->\n/m, "").replace(marker, `<script>\n${script}\n</script>`),
);
