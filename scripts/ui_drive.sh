#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Send touches to Caterpillar while it runs in the Simulator, without restarting it (so a booted
# Windows stays up). Screenshots land in build/ui-shots.
#   scripts/ui_drive.sh <simulator-udid> "tap 0.5 0.5; wait 2; shot after-tap"
# Actions: tap X Y | hold X Y SECONDS | drag X1 Y1 X2 Y2 | twotap | type TEXT | button LABEL
#          sysbutton LABEL | wait SECONDS | shot NAME   (X and Y are fractions of the screen)
# Run scripts/ui_test.sh once first: it builds the test bundle this uses.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
UDID="${1:?usage: $0 <simulator-udid> \"actions\"}"
ACTIONS="${2:?usage: $0 <simulator-udid> \"actions\"}"

PRODUCTS=build/DerivedData-sim/Build/Products
SRC="$(ls "$PRODUCTS"/*.xctestrun 2>/dev/null | head -n 1)"
[ -n "$SRC" ] || { echo "no test bundle; run scripts/ui_test.sh first" >&2; exit 1; }

# xcodebuild installs the "app under test" before every run, which would restart Caterpillar.
# Point the run at a stand-in copy with another bundle identifier, so the real app is left alone.
STUB="$PRODUCTS/Debug-iphonesimulator/CaterpillarStandIn.app"
if [ ! -d "$STUB" ]; then
    cp -R "$PRODUCTS/Debug-iphonesimulator/Caterpillar.app" "$STUB"
    rm -f "$STUB/code.fd"
    plutil -replace CFBundleIdentifier -string com.sytsu.caterpillar.standin "$STUB/Info.plist"
    codesign --force --sign - "$STUB" >/dev/null 2>&1
fi
RUN="$PRODUCTS/drive.xctestrun"
python3 - "$SRC" "$RUN" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    run = plistlib.load(f)
def retarget(target):
    old = target.get("UITargetAppPath")
    if not old:
        return
    new = old.replace("Caterpillar.app", "CaterpillarStandIn.app")
    target["UITargetAppPath"] = new
    target["DependentProductPaths"] = [new if p == old else p for p in target.get("DependentProductPaths", [])]
for key, value in run.items():
    if key == "TestConfigurations":
        for cfg in value:
            for target in cfg.get("TestTargets", []):
                retarget(target)
    elif isinstance(value, dict) and "TestBundlePath" in value:
        retarget(value)
with open(sys.argv[2], "wb") as f:
    plistlib.dump(run, f)
PY

mkdir -p build/ui-shots
LOG=build/ui-drive.log
set +e
TEST_RUNNER_CATERPILLAR_SHOTS="$ROOT/build/ui-shots" TEST_RUNNER_CATERPILLAR_ACTIONS="$ACTIONS" \
    xcodebuild test-without-building -xctestrun "$RUN" -destination "id=$UDID" \
    -only-testing:CaterpillarUITests/SmokeTests/testDrive > "$LOG" 2>&1
RC=$?
set -e
grep -E "Test Case .*(passed|failed)|error:" "$LOG" | sort -u | tail -n 10
exit $RC
