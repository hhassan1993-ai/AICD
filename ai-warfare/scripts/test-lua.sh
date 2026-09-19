#!/usr/bin/env bash
# scripts/test-lua.sh — run the offline FiveM runtime suite (tests/run_tests.lua).
#
# This EXECUTES the mission-engine Lua against tests/fivem_mock.lua (mock natives,
# virtual clock, shared state bags, simulated server + two clients). It is the only
# runtime validation possible in a container with no FXServer and no game client.
#
# Exits non-zero if any test fails.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LUA="${LUA:-lua5.4}"
if ! command -v "$LUA" >/dev/null 2>&1; then
    echo "error: $LUA not found on PATH" >&2
    exit 127
fi

echo "== mission-engine offline runtime tests =="
echo "root: $ROOT"
echo "lua : $("$LUA" -v 2>&1)"
echo

"$LUA" tests/run_tests.lua
status=$?

echo
if [ $status -eq 0 ]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (exit $status)"
fi
exit $status
