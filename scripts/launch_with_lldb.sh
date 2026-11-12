#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Enable JIT from a Mac instead of StikDebug: launch the installed app stopped, attach LLDB over
# the cable, answer its JIT requests, then detach. The app keeps running with JIT on.
#   scripts/launch_with_lldb.sh <device-udid> [bundle-id]
# Find the UDID with: xcrun devicectl list devices
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${1:?usage: $0 <device-udid> [bundle-id]}"
BUNDLE_ID="${2:-com.sytsu.caterpillar}"
LAUNCH_JSON="$ROOT/work/launch.json"

mkdir -p "$ROOT/work"
rm -f "$LAUNCH_JSON"

echo "[jit] Launching $BUNDLE_ID (--start-stopped) on $UDID..."
for attempt in 1 2 3 4 5; do
    if xcrun devicectl device process launch \
        --start-stopped \
        --terminate-existing \
        --device "$UDID" \
        --json-output "$LAUNCH_JSON" \
        "$BUNDLE_ID" || \
       xcrun devicectl device process launch \
        --no-activate \
        --start-stopped \
        --terminate-existing \
        --device "$UDID" \
        --json-output "$LAUNCH_JSON" \
        "$BUNDLE_ID"; then
        break
    fi
    echo "[jit] Attempt $attempt failed; retrying in 2s..."
    sleep 2
done

read -r PID CORE_ID < <(python3 -c "
import json
d = json.load(open('$LAUNCH_JSON'))
pid = d['result']['process']['processIdentifier']
cid = d.get('result', {}).get('device', {}).get('identifier') or '$UDID'
print(pid, cid)
")

echo "[jit] Attaching LLDB to PID=$PID on CoreDevice=$CORE_ID..."
sleep 1
PYTHONPATH="$ROOT/scripts" xcrun lldb -b \
    -o "script lldb.debugger.SetAsync(False)" \
    -o "device select $CORE_ID" \
    -o "device process attach -p $PID" \
    -o "command script import $ROOT/scripts/_lldb_txm_jit.py" \
    -o "txm_jit_run"
