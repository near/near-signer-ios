#!/usr/bin/env bash
# Runs every test that does not need a phone: Swift unit tests, the Python host end-to-end tests
# against near-signer-sim, and the real near-connect Ledger executor over emulated BLE.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== swift test"
swift test

echo "== python host <-> near-signer-sim"
swift build --product near-signer-sim
python3 -m unittest discover -s host/python -v

echo "== near-connect Ledger executor (upstream a705e63) <-> near-signer-sim"
# The simulator sends and receives BLE packets over TCP, standing in for the Bluetooth link.
.build/debug/near-signer-sim --ble-packets --port 9998 --auto-approve > /dev/null &
sim=$!
trap 'kill $sim 2>/dev/null || true' EXIT
sleep 1
node host/compat/near-connect-ledger-executor.mjs --port 9998 \
    --executor https://raw.githubusercontent.com/near/near-connect-ledger/a705e63/ledger-executor.js --expect-fast no

echo "== camera transfer: JavaScript unit tests"
node --test host/optical/test_optical.mjs

echo "== camera transfer: node sender -> near-signer-sim optical -> node verify"
# The same transfer, as the QR codes would carry it: frames with 30% lost and reordered, the
# simulator signs, and the response code is checked and the signature verified.
transfer_tx="DQAAAGFsaWNlLnRlc3RuZXQAxXHjPi42wsco1hfqd6iOIyDIaX6si0Y638ASi5aCXL8HAAAAAAAAAAsAAABib2IudGVzdG5ldDlKvrNecHYJ3o9ztj1DvRo3b/5nk1yqaJN90pvATmc8AQAAAAMAAIBxZDO2KaM9AQAAAAAA"
response="$(node host/optical/near-signer-qr.mjs sign-tx --tx "$transfer_tx" --frames-out 400 --loss 0.3 --shuffle \
    --session-id 0badcafe --seed 7 | .build/debug/near-signer-sim optical --auto-approve)"
node host/optical/near-signer-qr.mjs verify --response "$response" --session-id 0badcafe --tx "$transfer_tx" \
    --public-key ed25519:EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz

echo "== camera transfer, compressed: a 300 KB contract deployment"
# The payload travels deflated (README "Camera transfer" > Message); 800-byte codes, 20% lost.
deploy_tx="$(mktemp)"
trap 'kill $sim 2>/dev/null || true; rm -f "$deploy_tx"' EXIT
node scripts/make-deploy-tx.mjs > "$deploy_tx"
response="$(node host/optical/near-signer-qr.mjs sign-tx --tx-file "$deploy_tx" --frames-out 3000 --loss 0.2 --shuffle \
    --fragment-size 800 --session-id 0badcafe --seed 7 | .build/debug/near-signer-sim optical --auto-approve)"
node host/optical/near-signer-qr.mjs verify --response "$response" --session-id 0badcafe --tx-file "$deploy_tx" \
    --public-key ed25519:EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz

echo "== camera transfer: rust sender -> near-signer-sim optical -> rust verify"
# The third implementation (host/rust/near-signer-qr, for near-cli-rs) on the same pipe.
if command -v cargo > /dev/null; then
    cargo build --release --quiet --manifest-path host/rust/near-signer-qr/Cargo.toml
    rust_qr=host/rust/near-signer-qr/target/release/near-signer-qr
    response="$("$rust_qr" sign-tx --tx "$transfer_tx" --frames-out 400 --loss 0.3 --shuffle \
        --session-id 0badcafe --seed 7 | .build/debug/near-signer-sim optical --auto-approve)"
    "$rust_qr" verify --response "$response" --session-id 0badcafe --tx "$transfer_tx" \
        --public-key ed25519:EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz
    response="$("$rust_qr" sign-tx --tx-file "$deploy_tx" --frames-out 3000 --loss 0.2 --shuffle \
        --fragment-size 800 --session-id 0badcafe --seed 7 | .build/debug/near-signer-sim optical --auto-approve)"
    "$rust_qr" verify --response "$response" --session-id 0badcafe --tx-file "$deploy_tx" \
        --public-key ed25519:EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz
else
    echo "skipped: cargo is not installed"
fi
