#!/usr/bin/env bash
# Formats the code: Swift with SwiftFormat, Python with Ruff, JavaScript with Prettier, and lints
# Python (Ruff) and shell scripts (ShellCheck).
#
#   scripts/format.sh           format in place
#   scripts/format.sh --check   change nothing; fail if anything would change (CI runs this)
#
# Needs swiftformat, ruff, shellcheck and Node.js (Prettier runs through npx). On a Mac:
#   brew install swiftformat ruff shellcheck node
set -euo pipefail
cd "$(dirname "$0")/.."

prettier=prettier@3.9.9
js_files=(host/compat/*.mjs scripts/*.cjs scripts/*.mjs)

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

if $check; then
    step swiftformat --lint .
    step ruff format --check .
    step ruff check .
    step npx --yes "$prettier" --check "${js_files[@]}"
else
    step swiftformat --quiet .
    step ruff format .
    step ruff check --fix .
    step npx --yes "$prettier" --write --log-level warn "${js_files[@]}"
fi
step shellcheck scripts/*.sh

if [ "$status" -ne 0 ]; then
    $check && echo "Formatting or lint problems; scripts/format.sh fixes the formatting ones." >&2
    exit "$status"
fi
