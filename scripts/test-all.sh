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
