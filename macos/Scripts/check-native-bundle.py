#!/usr/bin/env python3
"""Validate that an artifact is the native universal app and its Share extension."""
import argparse
from pathlib import Path
import plistlib
import subprocess

# Apple silicon and Intel. The Intel slice builds but has not been run on an
# Intel Mac yet.
SLICES = {"arm64", "x86_64"}


def validate(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.komoliddin.ZapFastMac":
        raise SystemExit("Wrong bundle: expected the native macOS app.")
    if info.get("LSMinimumSystemVersion") != "15.0":
        raise SystemExit("Unexpected native minimum macOS version.")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    archs = set(subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split())
    if archs != SLICES:
        raise SystemExit("Native executable must contain exactly the arm64 and x86_64 slices.")
    linked = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    if "SwiftUI.framework" not in linked or "AppKit.framework" not in linked:
        raise SystemExit("Native executable is missing its SwiftUI/AppKit link.")
    share = app / "Contents/PlugIns/ZapFastShare.appex"
    extension = plistlib.loads((share / "Contents/Info.plist").read_bytes())
    if extension.get("CFBundleIdentifier") != "com.komoliddin.ZapFastMac.Share":
        raise SystemExit("Native Share extension is missing or has the wrong identity.")
    share_binary = share / "Contents/MacOS" / extension["CFBundleExecutable"]
    if set(subprocess.check_output(["lipo", "-archs", str(share_binary)], text=True).split()) != SLICES:
        raise SystemExit("Native Share extension must contain exactly the arm64 and x86_64 slices.")
    for name in ["LICENSE", "THIRD-PARTY-NOTICES.md", "DEPENDENCY-LICENSES.md"]:
        path = app / "Contents/Resources" / name
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit("Missing bundled notice: " + name)
    print("Native universal app, Share extension and bundled notices verified.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    validate(parser.parse_args().app)
