#!/usr/bin/env bash
# Regenerates test fixtures from near-api-js / near-seed-phrase / tweetnacl (needs node + npm).
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(cd "$work" && npm init -y >/dev/null && npm install --silent near-api-js@7.3.1 near-seed-phrase@0.2.1 tweetnacl@1.0.3)
node scripts/gen-fixtures.cjs "$work/node_modules" > "$work/fixtures.json"
python3 scripts/fixtures-to-swift.py "$work/fixtures.json"
echo "fixtures regenerated"
