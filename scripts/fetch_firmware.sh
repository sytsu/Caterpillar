#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Fetch the UEFI firmware the app ships: the EDK2 ArmVirtQemu build that QEMU distributes
# (edk2-stable202408), plus its licence text. Output: ios/Firmware/code.fd, edk2-licenses.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/ios/Firmware"
TAG="v10.1.0"
BASE="https://raw.githubusercontent.com/qemu/qemu/$TAG/pc-bios"
BZ2_SHA256="c023444108b7a132fdebf70c4765cd2dd9af2a9ff7d001a743aaabe87c20a458"
FD_SHA256="47765fe344818cbc464b1c14ae658fb4b854f5c2ceffa982411731eb4865594d"

mkdir -p "$OUT"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ -f "$OUT/code.fd" ] && [ "$(sha "$OUT/code.fd")" = "$FD_SHA256" ] && [ -s "$OUT/edk2-licenses.txt" ]; then
    echo "firmware already in $OUT"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL --retry 3 -o "$TMP/code.fd.bz2" "$BASE/edk2-aarch64-code.fd.bz2"
[ "$(sha "$TMP/code.fd.bz2")" = "$BZ2_SHA256" ] || { echo "firmware download does not match the pinned checksum" >&2; exit 1; }
bunzip2 "$TMP/code.fd.bz2"
[ "$(sha "$TMP/code.fd")" = "$FD_SHA256" ] || { echo "unpacked firmware does not match the pinned checksum" >&2; exit 1; }
curl -fL --retry 3 -o "$TMP/edk2-licenses.txt" "$BASE/edk2-licenses.txt"
mv "$TMP/code.fd" "$OUT/code.fd"
mv "$TMP/edk2-licenses.txt" "$OUT/edk2-licenses.txt"
echo "firmware written to $OUT"
