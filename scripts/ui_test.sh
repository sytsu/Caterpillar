#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Run the UI smoke tests in the iOS Simulator and collect screenshots in build/ui-shots.
#   scripts/ui_test.sh [simulator-udid] [-only-testing:CaterpillarUITests/SmokeTests/testHome ...]
# The app needs a disk image in its Documents/Machines/Win11 folder; an empty file of 64 MB or
# more is enough to reach the UEFI shell:
#   mkfile -n 80m "$(xcrun simctl get_app_container booted com.sytsu.caterpillar data)/Documents/Machines/Win11/windows11.img"
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEST="platform=iOS Simulator,name=iPhone 17"
if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
    DEST="id=$1"
    shift
fi

[ -f ios/deps-sim/lib/libslirp.a ] || bash scripts/build_ios_deps.sh simulator
bash scripts/fetch_firmware.sh
make -j"$(sysctl -n hw.ncpu)" sim-lib
xcodegen generate --quiet --spec ios/project.yml

SHOTS="$ROOT/build/ui-shots"
rm -rf "$SHOTS" build/ui-test.xcresult
mkdir -p "$SHOTS"
LOG=build/ui-test.log
set +e
TEST_RUNNER_CATERPILLAR_SHOTS="$SHOTS" xcodebuild test \
    -project ios/Caterpillar.xcodeproj -scheme Caterpillar -sdk iphonesimulator \
    -destination "$DEST" -derivedDataPath build/DerivedData-sim \
    -resultBundlePath build/ui-test.xcresult "$@" > "$LOG" 2>&1
RC=$?
set -e
grep -E "Test Case .*(passed|failed)|error:|XCTAssert|\*\* TEST" "$LOG" | sort -u | tail -n 40
ls "$SHOTS"
exit $RC
