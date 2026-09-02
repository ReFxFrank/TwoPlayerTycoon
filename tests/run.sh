#!/usr/bin/env bash
# Sanctum of Embers — headless test entry point.
#
#   ./tests/run.sh              syntax-check every .luau, then run every spec
#   ./tests/run.sh economy      run only specs whose name contains "economy"
#
# Requires the `luau` CLI (https://github.com/luau-lang/luau/releases) on PATH or in $LUAU_BIN,
# and Node 18+. Neither is needed to play the game — this is developer tooling only.
set -uo pipefail
cd "$(dirname "$0")/.."

LUAU_BIN="${LUAU_BIN:-luau}"
LUAU_COMPILE="${LUAU_COMPILE:-${LUAU_BIN%luau}luau-compile}"
if ! command -v "$LUAU_BIN" >/dev/null 2>&1; then
    echo "error: '$LUAU_BIN' not found. Install the Luau CLI or set LUAU_BIN." >&2
    exit 2
fi

fail=0
echo "== syntax =="
while IFS= read -r file; do
    if ! out=$("$LUAU_COMPILE" --binary "$file" 2>&1 >/dev/null); then
        echo "  x $file"
        echo "$out" | sed 's/^/      /'
        fail=1
    fi
done < <(find src tests -name '*.luau' | sort)
[ "$fail" -eq 0 ] && echo "  all files parse"

echo
echo "== house rules =="
./tests/lint.sh || fail=1

echo
echo "== specs =="
if [ "$#" -gt 0 ]; then
    LUAU_BIN="$LUAU_BIN" node tests/tools/bundle.mjs --only "$1" || fail=1
else
    LUAU_BIN="$LUAU_BIN" node tests/tools/bundle.mjs || fail=1
fi

exit "$fail"
