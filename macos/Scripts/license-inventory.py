#!/usr/bin/env python3
"""Collect locked native dependencies and their available license texts.

Declarations are evidence, not a license compatibility decision. Run after
resolving the Swift package. --check verifies the committed inventory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
MAC = ROOT / "macos"


# The app is universal: each slice may pull dependencies of its own.
PLATFORMS = ["aarch64-apple-darwin", "x86_64-apple-darwin"]


def bridge_metadata(platform):
    return json.loads(subprocess.check_output([
        "cargo", "metadata", "--locked", "--format-version", "1", "--filter-platform", platform,
        "--manifest-path", str(MAC / "Bridge/Cargo.toml")
    ]))


def merged(metadatas):
    """One graph with every package and dependency edge of the platforms'."""
    packages, nodes = {}, {}
    for metadata in metadatas:
        for package in metadata["packages"]:
            packages[package["id"]] = package
        for node in metadata["resolve"]["nodes"]:
            known = nodes.setdefault(node["id"], {"id": node["id"], "dependencies": []})
            known["dependencies"] = sorted(set(known["dependencies"]) | set(node["dependencies"]))
    return {"packages": list(packages.values()), "resolve": {"nodes": list(nodes.values())}}


def generate(metadata):
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    bridge = next(p["id"] for p in metadata["packages"] if p["name"] == "zapfast-bridge")
    seen, pending = set(), [bridge]
    while pending:
        package = pending.pop()
        if package not in seen:
            seen.add(package)
            pending.extend(nodes[package]["dependencies"])
    texts = {}

    def licenses(folder, explicit=None, recursive=True):
        def is_license(path):
            return (path.is_file() and path.suffix.lower() not in {".py", ".rs", ".swift", ".sh", ".json", ".toml", ".c", ".h", ".db", ".sqlite", ".log"}
                    and re.match(r"^(license|licence|copying|notice|copyright)([.\-_]|$)", path.name, re.I))
        files = []
        if recursive:
            for directory, dirs, names in os.walk(folder):
                dirs[:] = sorted(d for d in dirs if d not in {".git", ".build", "target", "Build", "node_modules", "__pycache__"})
                files.extend(Path(directory) / name for name in names if is_license(Path(directory) / name))
        else:
            files = [p for p in folder.iterdir() if is_license(p)]
        files.sort()
        if explicit:
            path = (folder / explicit).resolve()
            if not path.is_relative_to(folder.parent.parent.resolve()):
                raise SystemExit("License file is outside the package/workspace: " + folder.name)
            if path.is_file() and path.suffix.lower() not in {".db", ".sqlite", ".log"}:
                files.append(path)
        # Workspace crates can inherit the repository's license file.
        if not files:
            for ancestor in [folder.parent, folder.parent.parent]:
                inherited = [p for p in ancestor.glob("*") if p.is_file()
                             and re.match(r"^(license|licence|copying|notice)([.\-_]|$)", p.name, re.I)]
                if inherited:
                    files.extend(sorted(inherited))
                    break
        references = []
        for file in files:
            try:
                text = file.read_text(encoding="utf-8").strip()
            except UnicodeError:
                continue
            digest = hashlib.sha256(text.encode()).hexdigest()
            texts[digest] = text
            label = file.name.replace("|", "\\|")
            references.append(f"[{label}](#license-text-{digest})")
        return ", ".join(dict.fromkeys(references)) or "No license text found in package"

    lines = ["# Native dependency licenses", "", 
             "Generated from the locked macOS bridge dependency graph (Apple silicon and Intel,",
             "default features, so without the calls in development) and Swift pins.",
             "The Rust graph includes transitive build dependencies. Available package license",
             "and notice files are retained below, including bundled codec/library notices.",
             "This inventory does not establish compatibility or resolve conflicting headers.", "",
             "**Pending:** `wacore-libsignal` at `f7468ae2920a2b0aedbd0848cf121de56a07f93c`",
             "declares MIT in its manifest and contains Signal AGPL-3.0-only source headers.",
             "Binary distribution requires upstream clarification and a recorded review.", "",
             "The repository's LICENSE covers its own code. THIRD-PARTY-NOTICES.md covers",
             "the Pidgin sounds and other bundled assets. Dependency terms apply separately.", "",
             "## Rust packages", "", "| Package | Version | Declared license | Source | Texts |",
             "|---|---|---|---|---|"]
    packages = sorted((p for p in metadata["packages"] if p["id"] in seen), key=lambda p: (p["name"], p["version"]))
    for package in packages:
        folder = Path(package["manifest_path"]).parent
        source = package["source"] or "This repository"
        declaration = (package["license"] or "See license file").replace("|", "\\|")
        files = licenses(folder, package["license_file"], recursive=package["source"] is not None)
        lines.append(f'| {package["name"]} | {package["version"]} | {declaration} | {source} | {files} |')
    lines += ["", "## Swift packages", "", "| Package | Version / revision | License | Texts |", "|---|---|---|---|"]
    kit = MAC / "Packages/ZapFastKit"
    checkouts = {p.name.lower(): p for p in (kit / ".build/checkouts").iterdir() if p.is_dir()}
    for pin in json.loads((kit / "Package.resolved").read_text())["pins"]:
        declared = {"lottie-ios": "Apache-2.0", "phonenumberkit": "MIT"}[pin["identity"]]
        state = pin["state"]
        files = licenses(checkouts[pin["identity"]])
        lines.append(f'| [{pin["identity"]}]({pin["location"]}/tree/{state["revision"]}) | {state["version"]} / {state["revision"]} | {declared} | {files} |')
    for digest, text in sorted(texts.items()):
        fence = "`" * max(3, max((len(m) + 1 for m in re.findall(r"`+", text)), default=3))
        lines += ["", f"## License text {digest}", "", fence + "text", text, fence]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    metadata = json.loads(args.metadata.read_text()) if args.metadata else merged(
        bridge_metadata(platform) for platform in PLATFORMS
    )
    text = generate(metadata)
    target = MAC / "DEPENDENCY-LICENSES.md"
    if args.check:
        if target.read_text() != text:
            raise SystemExit("Native license inventory is stale. Run macos/Scripts/license-inventory.py.")
        print("Native license inventory is current.")
    else:
        target.write_text(text)
        print("Updated macos/DEPENDENCY-LICENSES.md")


if __name__ == "__main__":
    main()
