#!/usr/bin/env bash
# Formats the code: Swift with SwiftFormat, Python with Ruff, JavaScript with Prettier, Rust with
# rustfmt (when cargo is installed), and lints Python (Ruff), the camera-transfer JavaScript
# (ESLint, from host/optical/package.json) and shell scripts (ShellCheck).
#
#   scripts/format.sh           format in place
#   scripts/format.sh --check   change nothing; fail if anything would change (CI runs this)
#
# Needs swiftformat, ruff, shellcheck and Node.js (Prettier runs through npx). On a Mac:
#   brew install swiftformat ruff shellcheck node
set -euo pipefail
cd "$(dirname "$0")/.."

prettier=prettier@3.9.9
# The Rust crate is formatted when cargo is installed (CI's rust job always checks it).
rust_manifest=host/rust/near-signer-qr/Cargo.toml
# host/optical/vendor/ is third-party code; near-signer-qr-executor.js and near-signer-qr-camera.html
# are built from it.
js_files=(host/compat/*.mjs host/optical/*.mjs host/optical/executor/*.js host/optical/browser-test/*.mjs scripts/*.cjs scripts/*.mjs)

check=false
case "${1:-}" in
    --check) check=true ;;
    "") ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

# Runs every step, even after one fails, so a single run reports everything.
status=0
step() {
    echo "== $*"
    "$@" || status=1
}

# ESLint comes from host/optical's lockfile; installed once, again when the lockfile changes.
js_lint() {
    if [ ! -d host/optical/node_modules ] || [ host/optical/package-lock.json -nt host/optical/node_modules ]; then
        npm ci --prefix host/optical --no-audit --no-fund --loglevel error
    fi
    npm run --prefix host/optical --silent lint
}

if $check; then
    step swiftformat --lint .
    step ruff format --check .
    step ruff check .
    step npx --yes "$prettier" --check "${js_files[@]}"
    step js_lint
    if command -v cargo > /dev/null; then
        step cargo fmt --check --manifest-path "$rust_manifest"
    fi
else
    step swiftformat --quiet .
    step ruff format .
    step ruff check --fix .
    step npx --yes "$prettier" --write --log-level warn "${js_files[@]}"
    step js_lint
    if command -v cargo > /dev/null; then
        step cargo fmt --manifest-path "$rust_manifest"
    fi
fi
step shellcheck scripts/*.sh .github/scripts/*.sh

if [ "$status" -ne 0 ]; then
    $check && echo "Formatting or lint problems; scripts/format.sh fixes the formatting ones." >&2
    exit "$status"
fi
