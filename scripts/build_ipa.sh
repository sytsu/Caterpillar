#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Build Caterpillar.
#   scripts/build_ipa.sh              -> dist/Caterpillar.ipa (unsigned; install with a sideloading tool)
#   scripts/build_ipa.sh simulator    -> build/sim/Caterpillar.app for the iOS Simulator
# Needs Xcode, `brew install xcodegen meson ninja pkgconf`, and a network connection the first time
# (dependencies and firmware are downloaded once).
# Environment: BUNDLE_ID (default: the project's), VERSION, BUILD_NUMBER.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VARIANT="${1:-device}"

case "$VARIANT" in
    device)    SDK=iphoneos;        DEPS=ios/deps;     LIB_TARGET=ios-lib ;;
    simulator) SDK=iphonesimulator; DEPS=ios/deps-sim; LIB_TARGET=sim-lib ;;
    *) echo "usage: $0 [device|simulator]" >&2; exit 2 ;;
esac

[ -f "$DEPS/lib/libslirp.a" ] || bash scripts/build_ios_deps.sh "$VARIANT"
bash scripts/fetch_firmware.sh
make -j"$(sysctl -n hw.ncpu)" "$LIB_TARGET"
xcodegen generate --quiet --spec ios/project.yml

# Keep the full log; print only the result, or the errors if there are any.
run_xcodebuild() {
    local log="build/xcodebuild-$VARIANT.log"
    mkdir -p build
    if ! xcodebuild "$@" > "$log" 2>&1; then
        grep -E "error:|ld: |Undefined symbols" "$log" | sort -u | head -n 40 >&2
        echo "xcodebuild failed; full log in $log" >&2
        exit 1
    fi
    tail -n 2 "$log"
}

OVERRIDES=()
[ -n "${BUNDLE_ID:-}" ] && OVERRIDES+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
[ -n "${VERSION:-}" ] && OVERRIDES+=("MARKETING_VERSION=$VERSION")
[ -n "${BUILD_NUMBER:-}" ] && OVERRIDES+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")

if [ "$VARIANT" = simulator ]; then
    run_xcodebuild -project ios/Caterpillar.xcodeproj -scheme Caterpillar -configuration Debug \
        -sdk iphonesimulator -arch arm64 -derivedDataPath build/DerivedData-sim \
        ONLY_ACTIVE_ARCH=YES ${OVERRIDES[@]+"${OVERRIDES[@]}"} build
    rm -rf build/sim && mkdir -p build/sim
    cp -R build/DerivedData-sim/Build/Products/Debug-iphonesimulator/Caterpillar.app build/sim/
    echo "built build/sim/Caterpillar.app"
    exit 0
fi

run_xcodebuild -project ios/Caterpillar.xcodeproj -scheme Caterpillar -configuration Release \
    -sdk iphoneos -arch arm64 -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    ${OVERRIDES[@]+"${OVERRIDES[@]}"} build

APP="build/DerivedData/Build/Products/Release-iphoneos/Caterpillar.app"
[ -d "$APP" ] || { echo "build produced no app" >&2; exit 1; }

# Ad-hoc signature carrying the entitlements, so tools that keep them (TrollStore) see
# get-task-allow. Sideloading tools that sign with your own certificate replace this.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
codesign --force --sign - --entitlements ios/Caterpillar.entitlements "$STAGE/Payload/Caterpillar.app"

mkdir -p dist
rm -f dist/Caterpillar.ipa
( cd "$STAGE" && zip -qry "$ROOT/dist/Caterpillar.ipa" Payload )
ls -lh dist/Caterpillar.ipa
