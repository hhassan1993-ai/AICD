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
#   ./restart-and-check.sh [-s SECONDS] [-k] [-f EXTRA_REGEX] [--license-key KEY | -l KEY]
#     -s SECONDS         how long to let the server run before stopping (default 45)
#     -k                 keep running (don't kill the server after the window)
#     -f REGEX           extra case-insensitive regex to also flag as failure
#     -l, --license-key  FIVEM license key (see precedence below)
#
# Requires a license key, resolved in this order:
#   1. the --license-key / -l argument
#   2. the FIVEM_LICENSE_KEY environment variable
#   3. the first non-empty, non-comment line of server/license.key (gitignored;
#      see server/license.key.example)
# and server/artifact/run.sh present (the Linux FXServer artifact + its
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
LICENSE_KEY_ARG=""

usage() {
    echo "Usage: $0 [-s SECONDS] [-k] [-f EXTRA_REGEX] [--license-key KEY | -l KEY]" >&2
    exit 1
}

# Pull --license-key/-l out first (getopts below doesn't understand long
# options), leaving everything else for getopts to parse as before.
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --license-key)
            [ $# -ge 2 ] || { echo "FAILED: --license-key requires a value" >&2; exit 1; }
            LICENSE_KEY_ARG="$2"
            shift 2
            ;;
        --license-key=*)
            LICENSE_KEY_ARG="${1#--license-key=}"
            shift
            ;;
        -l)
            [ $# -ge 2 ] || { echo "FAILED: -l requires a value" >&2; exit 1; }
            LICENSE_KEY_ARG="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done
if [ ${#ARGS[@]} -gt 0 ]; then
    set -- "${ARGS[@]}"
else
    set --
fi

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

# Reads the first non-empty, non-comment line of a file, trimmed of
# surrounding whitespace, and prints it. Returns 1 if the file doesn't
# exist or has no such line.
read_license_from_file() {
    local file="$1"
    local line trimmed
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        trimmed="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$trimmed" in
            ''|'#'*) continue ;;
            *)
                printf '%s' "$trimmed"
                return 0
                ;;
        esac
    done <"$file"
    return 1
}

LICENSE_KEY=""
LICENSE_SOURCE=""
LICENSE_FILE="$REPO_ROOT/server/license.key"

if [ -n "$LICENSE_KEY_ARG" ]; then
    LICENSE_KEY="$LICENSE_KEY_ARG"
    LICENSE_SOURCE="--license-key argument"
elif [ -n "${FIVEM_LICENSE_KEY:-}" ]; then
    LICENSE_KEY="$FIVEM_LICENSE_KEY"
    LICENSE_SOURCE="FIVEM_LICENSE_KEY environment variable"
elif LICENSE_KEY="$(read_license_from_file "$LICENSE_FILE")"; then
    LICENSE_SOURCE="server/license.key"
fi

if [ -z "$LICENSE_KEY" ]; then
    echo "FAILED: no FiveM license key found. Provide one via --license-key <key>, the FIVEM_LICENSE_KEY environment variable, or by creating server/license.key (see server/license.key.example; the file is gitignored and never committed). Get a free key at https://portal.cfx.re" >&2
    exit 1
fi

KEY_LEN=${#LICENSE_KEY}
KEY_PREFIX="${LICENSE_KEY:0:5}"
echo "license key: loaded from $LICENSE_SOURCE (${KEY_PREFIX}…, ${KEY_LEN} chars)"

mkdir -p "$LOGS_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_PATH="$LOGS_DIR/fxserver-$TIMESTAMP.log"

echo "==> Starting FXServer for ${SECONDS_TO_RUN}s..."
echo "    Working directory: $REPO_ROOT"
echo "    Log: $LOG_PATH"

(
    cd "$REPO_ROOT"
    # Key last; server.cfg does not set sv_licenseKey. Same order as the
    # Windows launchers.
    exec "$RUN_SH" \
        +set citizen_dir "$ARTIFACT_DIR/citizen" \
        +exec server/server.cfg \
        +set sv_licenseKey "$LICENSE_KEY"
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
