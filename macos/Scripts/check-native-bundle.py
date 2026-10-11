#!/usr/bin/env python3
"""Validate that an artifact is the native arm64 app and its Share extension."""
import argparse
from pathlib import Path
import plistlib
import subprocess


def validate(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.komoliddin.ZapFastMac":
        raise SystemExit("Wrong bundle: expected the native macOS app.")
    if info.get("LSMinimumSystemVersion") != "15.0":
        raise SystemExit("Unexpected native minimum macOS version.")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    if arch != "arm64":
        raise SystemExit("Native executable must contain exactly the arm64 slice.")
    linked = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    if "SwiftUI.framework" not in linked or "AppKit.framework" not in linked:
        raise SystemExit("Native executable is missing its SwiftUI/AppKit link.")
    share = app / "Contents/PlugIns/ZapFastShare.appex"
    extension = plistlib.loads((share / "Contents/Info.plist").read_bytes())
    if extension.get("CFBundleIdentifier") != "com.komoliddin.ZapFastMac.Share":
        raise SystemExit("Native Share extension is missing or has the wrong identity.")
    share_binary = share / "Contents/MacOS" / extension["CFBundleExecutable"]
    if subprocess.check_output(["lipo", "-archs", str(share_binary)], text=True).strip() != "arm64":
        raise SystemExit("Native Share extension must contain exactly the arm64 slice.")
    for name in ["LICENSE", "THIRD-PARTY-NOTICES.md", "DEPENDENCY-LICENSES.md"]:
        path = app / "Contents/Resources" / name
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit("Missing bundled notice: " + name)
    print("Native arm64 app, Share extension and bundled notices verified.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    validate(parser.parse_args().app)
