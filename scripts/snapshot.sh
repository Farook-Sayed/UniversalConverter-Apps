#!/bin/bash
# Builds the app, then runs it in snapshot mode and saves pictures of its windows to build/snapshots,
# once in light mode and once in dark mode. Used to check the design without a screen recording.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/make-app.sh >/dev/null

OUT="$PWD/build/snapshots"
rm -rf "$OUT"
mkdir -p "$OUT"

for mode in 0 1; do
    FC_SNAPSHOT="$OUT" FC_SNAPSHOT_SAMPLES="$PWD/TestFiles" FC_SNAPSHOT_DARK="$mode" \
        "build/Universal Converter.app/Contents/MacOS/Universal Converter" >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
done

ls "$OUT"
