#!/usr/bin/env python3
"""Keep the interface's string catalog in step with the code.

Every user-visible string in ZapFastKit is either a SwiftUI literal or a
`String(localized:)`. Neither names a bundle, so both are looked up in the
app's main bundle, in App/Resources/Localizable.xcstrings. Xcode does not
extract a local package's strings into the app's catalog, so this script asks
the compiler for them (`-emit-localized-strings`) and updates the catalog:
new keys are added, keys no longer in the code are marked stale, and
translations are kept.

    update-strings.py                     extract and update the catalog
    update-strings.py --import ru=FILE    also merge translations from JSON
    update-strings.py --check             fail if a key lacks a translation

A JSON import maps each key to a string, or to {"plural": {"one": ..,
"few": .., "many": .., "other": ..}} for a key whose words follow a number.
"""
import argparse
import json
from pathlib import Path
import subprocess

MAC = Path(__file__).resolve().parents[1]
KIT = MAC / "Packages/ZapFastKit"
CATALOG = MAC / "App/Resources/Localizable.xcstrings"
BUILD = MAC / "Build/strings"
LANGUAGES = ["ru"]


def extract():
    """Every key the compiler finds in ZapFastKit, with where it was seen."""
    subprocess.run([
        "swift", "build", "--package-path", str(KIT), "--scratch-path", str(BUILD),
        "-Xswiftc", "-emit-localized-strings",
        "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", str(BUILD / "stringsdata"),
    ], check=True)
    keys = {}
    for data in sorted(BUILD.glob("out/Intermediates.noindex/ZapFastKit.build/*/*/Objects-normal/*/*.stringsdata")):
        parsed = json.loads(data.read_text())
        for entry in parsed.get("tables", {}).get("Localizable", []):
            # The in-chat search reads its own table, Search.strings.
            if not entry["key"].startswith("search."):
                keys.setdefault(entry["key"], entry.get("comment") or "")
    if not keys:
        raise SystemExit("The compiler reported no strings; the build layout may have changed.")
    return keys


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def localization(value):
    if isinstance(value, dict):
        return {"variations": {"plural": {form: unit(text) for form, text in value["plural"].items()}}}
    return unit(value)


def missing(catalog):
    gaps = []
    for key, entry in catalog["strings"].items():
        if entry.get("extractionState") == "stale" or entry.get("shouldTranslate") is False:
            continue
        for language in LANGUAGES:
            if language not in entry.get("localizations", {}):
                gaps.append(f"{language}: {key}")
    return gaps


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--import", dest="imports", action="append", default=[], metavar="LANG=FILE")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    catalog = json.loads(CATALOG.read_text()) if CATALOG.exists() else {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    if args.check:
        gaps = missing(catalog)
        if gaps:
            raise SystemExit("Untranslated strings:\n" + "\n".join(gaps))
        print(f"All {len(catalog['strings'])} strings are translated.")
        return

    found = extract()
    strings = catalog["strings"]
    for key, comment in found.items():
        entry = strings.setdefault(key, {})
        entry.pop("extractionState", None)
        if comment:
            entry["comment"] = comment
    for key, entry in strings.items():
        if key not in found:
            entry["extractionState"] = "stale"
    for spec in args.imports:
        language, _, path = spec.partition("=")
        for key, value in json.loads(Path(path).read_text()).items():
            if key in strings:
                strings[key].setdefault("localizations", {})[language] = localization(value)
    catalog["strings"] = dict(sorted(strings.items()))
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n")
    gaps = missing(catalog)
    print(f"{len(found)} strings in the code, {len(gaps)} translations missing.")


if __name__ == "__main__":
    main()
