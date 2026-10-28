// ESLint for host/optical: the shared modules run in browsers and in Node, the CLI and the tests
// in Node, and executor/main.js and executor/camera.js as plain scripts inside their bundles, where
// the modules' exports are plain top-level names (scripts/build-optical-executor.mjs). Run with `npm run lint`;
// scripts/format.sh --check runs it too.
import fs from "node:fs";
import js from "@eslint/js";
import globals from "globals";

/// The names a module exports, as the bundle leaves them in scope for the executor.
function exportedNames(file) {
    const source = fs.readFileSync(new URL(file, import.meta.url), "utf8");
    const names = [];
    for (const match of source.matchAll(/^export (?:async function|function|const|let|class) (\w+)/gm))
        names.push(match[1]);
    for (const match of source.matchAll(/^export \{([^}]*)\}/gm)) {
        for (const name of match[1].split(","))
            names.push(
                name
                    .trim()
                    .split(/\s+as\s+/)
                    .pop(),
            );
    }
    return Object.fromEntries(names.filter(Boolean).map((name) => [name, "readonly"]));
}

export default [
    {
        ignores: [
            "vendor/",
            "near-signer-qr-executor.js",
            "near-signer-qr-camera.html",
            "browser-test/node_modules/",
            "browser-test/shots/",
            "browser-test/preview/",
        ],
    },
    js.configs.recommended,
    {
        languageOptions: { ecmaVersion: "latest", sourceType: "module" },
        rules: {
            // `catch (error)` with the error unused is how an optional step is skipped.
            "no-unused-vars": ["error", { caughtErrors: "none" }],
        },
    },
    {
        files: ["*.mjs"],
        languageOptions: { globals: { ...globals.browser, ...globals.node } },
    },
    {
        // Node scripts whose page.evaluate callbacks run in the browser.
        files: ["browser-test/*.mjs"],
        languageOptions: { globals: { ...globals.node, ...globals.browser } },
    },
    {
        files: ["executor/main.js"],
        languageOptions: {
            sourceType: "script",
            globals: {
                ...globals.browser,
                qrcode: "readonly", // vendor/qrcode-generator.js, bundled first
                ...exportedNames("./optical.mjs"),
                ...exportedNames("./borsh.mjs"),
                ...exportedNames("./qr.mjs"),
                ...exportedNames("./scan.mjs"),
            },
        },
    },
    {
        files: ["executor/camera.js"],
        languageOptions: {
            sourceType: "script",
            globals: { ...globals.browser, ...exportedNames("./optical.mjs"), ...exportedNames("./scan.mjs") },
        },
    },
];
