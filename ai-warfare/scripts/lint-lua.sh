#!/usr/bin/env bash
# lint-lua.sh — syntax-check every .lua file under resources/ with luac5.4 -p.
# This is the ONLY runtime-independent validation available in this container
# (ENGINE-SPEC.md §8). It does not verify natives, logic, or runtime behavior
# — only that each file parses as valid Lua 5.4.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES_DIR="$REPO_ROOT/resources"

LUAC_BIN="${LUAC_BIN:-luac5.4}"

if ! command -v "$LUAC_BIN" >/dev/null 2>&1; then
    echo "FAILED: $LUAC_BIN not found on PATH." >&2
    exit 1
fi

if [ ! -d "$RESOURCES_DIR" ]; then
    echo "No resources/ directory found at $RESOURCES_DIR yet; nothing to lint."
    exit 0
fi

FAIL=0
COUNT=0

while IFS= read -r -d '' file; do
    COUNT=$((COUNT + 1))
    rel="${file#"$REPO_ROOT"/}"
    if "$LUAC_BIN" -p "$file" >/tmp/lint-lua-output.$$ 2>&1; then
        echo "OK   $rel"
    else
        echo "FAIL $rel"
        sed 's/^/     /' /tmp/lint-lua-output.$$
        FAIL=1
    fi
    rm -f /tmp/lint-lua-output.$$
done < <(find "$RESOURCES_DIR" -type f -name '*.lua' -print0 | sort -z)

echo ""
if [ "$COUNT" -eq 0 ]; then
    echo "No .lua files found under resources/."
elif [ "$FAIL" -eq 0 ]; then
    echo "RESULT: PASS ($COUNT file(s) OK)"
else
    echo "RESULT: FAIL"
fi

exit "$FAIL"
