#!/usr/bin/env bash
# restart-and-check.sh — Linux equivalent of restart-and-check.ps1
# (ENGINE-SPEC.md §3.5 loop): start run.sh, let it run, capture the log,
# stop it, grep for error signatures, PASS/FAIL, exit 1 on FAIL.
#
# Layout decision (matches restart-and-check.ps1 / server/server.cfg):
# FXServer's run.sh is launched with its WORKING DIRECTORY set to the
# ai-warfare REPO ROOT, and server.cfg is loaded relative to that root
# (+exec server/server.cfg), so a single resources/ folder at the repo
# root serves both resources/[mission]/ and the standard cfx-server-data
# resources copied alongside it by get-server.ps1 (or an equivalent Linux
# setup step — this repo's get-server.ps1 targets Windows only, per spec).
#
# Usage:
#   ./restart-and-check.sh [-s SECONDS] [-k] [-f EXTRA_REGEX]
#     -s SECONDS   how long to let the server run before stopping (default 45)
#     -k           keep running (don't kill the server after the window)
#     -f REGEX     extra case-insensitive regex to also flag as failure
#
# Requires: FIVEM_LICENSE_KEY environment variable set, and
# server/artifact/run.sh present (the Linux FXServer artifact + its
# alongside "run.sh" launcher, extracted the same way get-server.ps1 does
# for Windows — NOT produced by any script in this repo, since this repo's
# get-server.ps1 is Windows-only per the deliverable spec).
#
# NOT run against a real FXServer in this environment (no network access to
# runtime.fivem.net from this container). See README.md "Verified vs.
# unverified".

set -euo pipefail

SECONDS_TO_RUN=45
KEEP_RUNNING=0
EXTRA_FILTER=""

usage() {
    echo "Usage: $0 [-s SECONDS] [-k] [-f EXTRA_REGEX]" >&2
    exit 1
}

while getopts "s:kf:h" opt; do
    case "$opt" in
        s) SECONDS_TO_RUN="$OPTARG" ;;
        k) KEEP_RUNNING=1 ;;
        f) EXTRA_FILTER="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/server/artifact"
RUN_SH="$ARTIFACT_DIR/run.sh"
LOGS_DIR="$REPO_ROOT/logs"

BUILTIN_PATTERN='error|failed to load|exception|SCRIPT ERROR|Couldn'"'"'t find resource|not found'
if [ -n "$EXTRA_FILTER" ]; then
    COMBINED_PATTERN="(${BUILTIN_PATTERN})|(${EXTRA_FILTER})"
else
    COMBINED_PATTERN="(${BUILTIN_PATTERN})"
fi

if [ ! -x "$RUN_SH" ] && [ ! -f "$RUN_SH" ]; then
    echo "FAILED: run.sh not found at $RUN_SH. Download and extract the Linux FXServer artifact into server/artifact/ first." >&2
    exit 1
fi

if [ -z "${FIVEM_LICENSE_KEY:-}" ]; then
    echo "FAILED: environment variable FIVEM_LICENSE_KEY is not set. Get a free key at https://portal.cfx.re and: export FIVEM_LICENSE_KEY=<key>" >&2
    exit 1
fi

mkdir -p "$LOGS_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_PATH="$LOGS_DIR/fxserver-$TIMESTAMP.log"

echo "==> Starting FXServer for ${SECONDS_TO_RUN}s..."
echo "    Working directory: $REPO_ROOT"
echo "    Log: $LOG_PATH"

(
    cd "$REPO_ROOT"
    exec "$RUN_SH" \
        +set citizen_dir "$ARTIFACT_DIR/citizen" \
        +set sv_licenseKey "$FIVEM_LICENSE_KEY" \
        +exec server/server.cfg
) >"$LOG_PATH" 2>&1 &
SERVER_PID=$!

sleep "$SECONDS_TO_RUN"

if [ "$KEEP_RUNNING" -eq 0 ]; then
    echo "==> Stopping FXServer (PID $SERVER_PID)..."
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$SERVER_PID" 2>/dev/null || true
    fi
else
    echo "==> -k set; leaving FXServer running (PID $SERVER_PID)."
fi

echo ""
echo "==> Scanning log for error signatures..."

MATCHES="$(grep -inE "$COMBINED_PATTERN" "$LOG_PATH" || true)"

if [ -n "$MATCHES" ]; then
    echo ""
    echo "$MATCHES"
    echo ""
    MATCH_COUNT="$(printf '%s\n' "$MATCHES" | wc -l)"
    echo "RESULT: FAIL ($MATCH_COUNT matching line(s)). Log: $LOG_PATH"
    exit 1
else
    echo ""
    echo "RESULT: PASS (no error signatures found). Log: $LOG_PATH"
    exit 0
fi
