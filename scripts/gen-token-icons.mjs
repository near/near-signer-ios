#!/usr/bin/env node
// Renders the icons of the built-in token list (Sources/NearSignerCore/Near/Tokens.swift) into the
// app's asset catalog. Icons come from each token's on-chain `ft_metadata`, so they are the
// issuers' own. NEAR and wNEAR use the NEAR symbol.
//
//   npm install @resvg/resvg-js@2.6.2      (here, or anywhere on NODE_PATH)
//   node scripts/gen-token-icons.mjs
import { mkdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// require() honours NODE_PATH, unlike import.
const { Resvg } = createRequire(import.meta.url)("@resvg/resvg-js");

const RPC = process.env.NEAR_RPC ?? "https://free.rpc.fastnear.com";
const SIZE = 144; // 3x of 48 pt
const OUT = join(dirname(fileURLToPath(import.meta.url)), "../iOS/NearSigner/Assets.xcassets/Tokens");

// asset name -> contract (must match Tokens.swift)
const TOKENS = {
    "token-usdc": "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1",
    "token-usdt": "usdt.tether-token.near",
    "token-usdc-e": "a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48.factory.bridge.near",
    "token-usdt-e": "dac17f958d2ee523a2206206994597c13d831ec7.factory.bridge.near",
    "token-wbtc": "2260fac5e5542a773aa44fbcfedf7c193bc2c599.factory.bridge.near",
    "token-dai": "6b175474e89094c44da98b954eedeac495271d0f.factory.bridge.near",
    "token-aurora": "aaaaaa20d9e0e2461697782ef11675f668207961.factory.bridge.near",
    "token-ref": "token.v2.ref-finance.near",
    "token-stnear": "meta-pool.near",
    "token-linear": "linear-protocol.near",
    "token-sweat": "token.sweat",
    "token-nbtc": "nbtc.bridge.near",
    "token-eth-bridge": "eth.bridge.near",
    "token-btc": "btc.omft.near",
    "token-eth": "eth.omft.near",
    "token-sol": "sol.omft.near",
    "token-zec": "zec.omft.near",
    "token-xrp": "xrp.omft.near",
};

// The NEAR symbol from the near.org header (viewBox 0 0 16 16), white on a black circle.
const NEAR_SYMBOL =
    "M13.9017 0.646973C13.3462 0.646973 12.8304 0.929357 12.5394 1.39357L9.40403 5.95741C9.30186 6.10784 9.34331 6.31059 9.49675 6.41075C9.6211 6.49202 9.78561 6.48196 9.89889 6.38645L12.9851 3.76201C13.0364 3.71677 13.1154 3.72137 13.1616 3.77165C13.1825 3.79469 13.1937 3.82444 13.1937 3.85502V12.0719C13.1937 12.1397 13.1377 12.1942 13.0684 12.1942C13.0312 12.1942 12.9962 12.1783 12.9727 12.1502L3.6435 1.20169C3.33966 0.850174 2.89352 0.647392 2.42388 0.646973H2.09782C1.21536 0.646973 0.5 1.34833 0.5 2.2135V13.7863C0.5 14.6515 1.21536 15.3528 2.09782 15.3528C2.65336 15.3528 3.16915 15.0704 3.46017 14.6062L6.59558 10.0424C6.69769 9.89194 6.65624 9.68919 6.50279 9.58903C6.37845 9.50776 6.21394 9.51782 6.10071 9.61334L3.01446 12.2378C2.96318 12.283 2.88412 12.2784 2.83797 12.2281C2.81703 12.2051 2.80592 12.1753 2.80634 12.1447V3.92583C2.80634 3.85796 2.86232 3.80349 2.93155 3.80349C2.96831 3.80349 3.00377 3.81941 3.02728 3.84748L12.3552 14.7981C12.659 15.1496 13.1052 15.3524 13.5749 15.3528H13.9009C14.7833 15.3532 15.4992 14.6523 15.5 13.7871V2.2135C15.5 1.34833 14.7842 0.646973 13.9017 0.646973Z";
const NEAR_ICON = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><circle cx="16" cy="16" r="16" fill="#000"/><g transform="translate(8 8)"><path d="${NEAR_SYMBOL}" fill="#fff"/></g></svg>`;

async function metadata(contract) {
    const response = await fetch(RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            method: "query",
            params: {
                request_type: "call_function",
                finality: "final",
                account_id: contract,
                method_name: "ft_metadata",
                args_base64: "e30=",
            },
        }),
    });
    const json = await response.json();
    if (!json.result?.result) throw new Error(`${contract}: ${JSON.stringify(json.error ?? json.result)}`);
    return JSON.parse(Buffer.from(json.result.result).toString("utf8"));
}

// Icons drawn in white on transparent need a backdrop to show in light mode.
const BACKDROP = { "token-ref": "#000" };

/// An icon data URI as an SVG document (raster icons are embedded as images).
function iconSvg(dataUri, backdrop) {
    if (backdrop) {
        return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${SIZE}" height="${SIZE}"><circle cx="${SIZE / 2}" cy="${SIZE / 2}" r="${SIZE / 2}" fill="${backdrop}"/><image x="${SIZE * 0.18}" y="${SIZE * 0.18}" width="${SIZE * 0.64}" height="${SIZE * 0.64}" xlink:href="${dataUri}"/></svg>`;
    }
    const comma = dataUri.indexOf(",");
    const header = dataUri.slice(5, comma);
    const payload = dataUri.slice(comma + 1);
    if (header.startsWith("image/svg+xml")) {
        return header.endsWith(";base64")
            ? Buffer.from(payload, "base64").toString("utf8")
            : decodeURIComponent(payload);
    }
    return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${SIZE}" height="${SIZE}"><image width="${SIZE}" height="${SIZE}" xlink:href="${dataUri}"/></svg>`;
}

function writeImageSet(name, svg) {
    const png = new Resvg(svg, { fitTo: { mode: "width", value: SIZE }, background: "rgba(0,0,0,0)" }).render().asPng();
    const dir = join(OUT, `${name}.imageset`);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `${name}.png`), png);
    writeFileSync(
        join(dir, "Contents.json"),
        JSON.stringify(
            {
                images: [{ filename: `${name}.png`, idiom: "universal" }],
                info: { author: "xcode", version: 1 },
            },
            null,
            2,
        ) + "\n",
    );
    console.log(`${name}: ${png.length} bytes`);
}

mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, "Contents.json"), JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2) + "\n");
writeImageSet("token-near", NEAR_ICON);
for (const [name, contract] of Object.entries(TOKENS)) {
    const meta = await metadata(contract);
    if (!meta.icon) {
        console.log(`${name}: no icon on chain`);
        continue;
    }
    writeImageSet(name, iconSvg(meta.icon, BACKDROP[name]));
}
