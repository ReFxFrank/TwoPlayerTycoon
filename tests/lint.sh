#!/usr/bin/env bash
# Sanctum of Embers — house-rule checks.
#
# These are the project's own constraints, enforced rather than spot-checked: modern Luau idioms
# only, --!strict everywhere, a header comment on every module, and no file past the 300-line
# ceiling. Run by tests/run.sh; exits non-zero on any violation.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
note() { echo "  x $1"; fail=1; }

# 1. Deprecated / banned APIs. Each pattern is a global call, so it is matched with a leading
#    non-identifier character to avoid flagging task.wait, os.clock, :Connect and friends.
BANNED='(^|[^%[:alnum:]_.:])(wait|spawn|delay|elapsedTime|LoadLibrary|printidentity)\(|:connect\(|:remove\(|game\.Workspace|Instance:Remove|FilteringEnabled|:Destroy\(\)\s*;\s*:'
while IFS= read -r file; do
    if hits=$(grep -nE "$BANNED" "$file" | grep -v '^\s*--' | grep -vE '^\s*[0-9]+:\s*--'); then
        [ -n "$hits" ] && note "$file uses a deprecated API:" && echo "$hits" | sed 's/^/        /'
    fi
done < <(find src -name '*.luau' | sort)

# 2. --!strict on the first line.
while IFS= read -r file; do
    [ "$(head -1 "$file")" = "--!strict" ] || note "$file does not open with --!strict"
done < <(find src -name '*.luau' | sort)

# 3. A header comment block in the first few lines.
while IFS= read -r file; do
    head -4 "$file" | grep -q -- '--\[\[' || note "$file has no header comment block"
done < <(find src -name '*.luau' | sort)

# 4. The 300-line ceiling.
while IFS= read -r file; do
    lines=$(wc -l < "$file")
    [ "$lines" -le 300 ] || note "$file is $lines lines (ceiling is 300)"
done < <(find src -name '*.luau' | sort)

# 5. tests/ must never be synced into the game.
if grep -q '"tests' default.project.json; then
    note "default.project.json references tests/ — dev tooling must not ship"
fi

# 6. The client must not be able to name a DataStore or write currency directly.
while IFS= read -r file; do
    grep -q 'DataStoreService' "$file" && note "$file (client) touches DataStoreService"
done < <(find src/client -name '*.luau' 2>/dev/null | sort)

[ "$fail" -eq 0 ] && echo "  house rules pass"
exit "$fail"
