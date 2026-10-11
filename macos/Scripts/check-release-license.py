#!/usr/bin/env python3
"""Refuse binary distribution with pending or stale dependency review."""
import hashlib
import json
from pathlib import Path

MAC = Path(__file__).resolve().parents[1]


def validate(review, mac=MAC):
    if review.get("status") != "resolved" or not review.get("decision", "").strip():
        raise SystemExit("Native binary release is blocked: dependency license review is pending. " + review.get("decision", ""))
    for field, path in [("bridge_lock_sha256", mac / "Bridge/Cargo.lock"),
                        ("swift_lock_sha256", mac / "Packages/ZapFastKit/Package.resolved")]:
        if review.get(field) != hashlib.sha256(path.read_bytes()).hexdigest():
            raise SystemExit("Native binary release is blocked: dependency license review does not match " + path.name)


if __name__ == "__main__":
    validate(json.loads((MAC / "release-license-review.json").read_text()))
    print("Recorded license review matches both native dependency locks.")
