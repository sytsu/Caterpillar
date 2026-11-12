#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Print an AltStore/SideStore source (repo.json) for a built Caterpillar.ipa.

    VERSION=1.0 python3 scripts/make_source.py dist/Caterpillar.ipa > dist/repo.json

The source is published as a release asset, so
https://github.com/<owner>/<repo>/releases/latest/download/repo.json always describes the newest build.
"""
import datetime
import json
import os
import plistlib
import sys
import zipfile

ipa = sys.argv[1]
repo = os.environ.get("GITHUB_REPOSITORY", "sytsu/Caterpillar")
with zipfile.ZipFile(ipa) as z:
    name = next(n for n in z.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))
    info = plistlib.loads(z.read(name))

version = os.environ.get("VERSION") or info["CFBundleShortVersionString"]
build = os.environ.get("BUILD_NUMBER") or info["CFBundleVersion"]
tag = os.environ.get("GITHUB_REF_NAME") or f"v{version}"
raw = f"https://raw.githubusercontent.com/{repo}/main"

source = {
    "name": "Caterpillar",
    "identifier": "io.github." + repo.replace("/", ".").lower(),
    "subtitle": "Windows 11 on ARM, on iPhone and iPad",
    "website": f"https://github.com/{repo}",
    "apps": [
        {
            "name": "Caterpillar",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": repo.split("/")[0],
            "subtitle": "Windows 11 on ARM, on iPhone and iPad",
            "localizedDescription": (
                "Runs Windows 11 for ARM64 with its own JIT. Bring your own Windows disk image. "
                "Needs JIT (StikDebug) and an 8 GB device for comfortable use."
            ),
            "iconURL": f"{raw}/ios/Sources/Assets.xcassets/AppIcon.appiconset/icon.png",
            "tintColor": "#A8D18C",
            "category": "utilities",
            "versions": [
                {
                    "version": version,
                    "buildVersion": str(build),
                    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/Caterpillar.ipa",
                    "size": os.path.getsize(ipa),
                    "minOSVersion": info.get("MinimumOSVersion", "17.0"),
                }
            ],
            "appPermissions": {
                "entitlements": ["get-task-allow"],
                "privacy": {"NSMicrophoneUsageDescription": info.get("NSMicrophoneUsageDescription", "")},
            },
        }
    ],
    "news": [],
}
json.dump(source, sys.stdout, indent=2)
print()
