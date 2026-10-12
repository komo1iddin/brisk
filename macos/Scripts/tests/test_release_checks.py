import hashlib
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


license_check = load("check-release-license")
bundle_check = load("check-native-bundle")


class ReleaseChecks(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="zapfast-release-check-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)

    def review(self):
        review = {"status": "resolved", "decision": "Synthetic fixture only, no distribution authorization."}
        for field, name in [("bridge_lock_sha256", "Bridge/Cargo.lock"),
                            ("swift_lock_sha256", "Packages/ZapFastKit/Package.resolved")]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic locked dependencies")
            review[field] = hashlib.sha256(path.read_bytes()).hexdigest()
        return review

    def test_pending_review_never_allows_packaging(self):
        review = self.review()
        review["status"] = "pending"
        with self.assertRaisesRegex(SystemExit, "pending"):
            license_check.validate(review, self.root)

    def test_each_dependency_lock_invalidates_an_old_review(self):
        for name in ["Bridge/Cargo.lock", "Packages/ZapFastKit/Package.resolved"]:
            with self.subTest(lock=name):
                review = self.review()
                (self.root / name).write_bytes(b"changed dependencies")
                with self.assertRaisesRegex(SystemExit, "does not match"):
                    license_check.validate(review, self.root)

    def test_matching_review_passes_but_an_empty_decision_does_not(self):
        review = self.review()
        license_check.validate(review, self.root)
        review["decision"] = " "
        with self.assertRaises(SystemExit):
            license_check.validate(review, self.root)

    def app(self, identifier="com.komoliddin.ZapFastMac"):
        app = self.root / "ZapFast.app"
        info = app / "Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier, "CFBundleExecutable": "ZapFast", "LSMinimumSystemVersion": "15.0"}))
        share = app / "Contents/PlugIns/ZapFastShare.appex/Contents/Info.plist"
        share.parent.mkdir(parents=True)
        share.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.komoliddin.ZapFastMac.Share", "CFBundleExecutable": "ZapFastShare"}))
        resources = app / "Contents/Resources"
        resources.mkdir()
        for name in ["LICENSE", "THIRD-PARTY-NOTICES.md", "DEPENDENCY-LICENSES.md"]:
            (resources / name).write_text("synthetic notice")
        return app

    def test_an_egui_bundle_is_rejected_before_inspecting_its_binary(self):
        with patch.object(bundle_check.subprocess, "check_output") as binary_tool:
            with self.assertRaisesRegex(SystemExit, "Wrong bundle"):
                bundle_check.validate(self.app(identifier="dev.carminepaolino.zapfast"))
            binary_tool.assert_not_called()

    def test_missing_notices_prevent_an_otherwise_native_bundle(self):
        app = self.app()
        (app / "Contents/Resources/DEPENDENCY-LICENSES.md").unlink()
        def binary_tool(args, **kwargs):
            return "arm64 x86_64" if args[0] == "lipo" else "SwiftUI.framework AppKit.framework"
        with patch.object(bundle_check.subprocess, "check_output", side_effect=binary_tool):
            with self.assertRaisesRegex(SystemExit, "Missing bundled notice"):
                bundle_check.validate(app)

    def test_an_apple_silicon_only_bundle_is_rejected(self):
        def binary_tool(args, **kwargs):
            return "arm64" if args[0] == "lipo" else "SwiftUI.framework AppKit.framework"
        with patch.object(bundle_check.subprocess, "check_output", side_effect=binary_tool):
            with self.assertRaisesRegex(SystemExit, "x86_64"):
                bundle_check.validate(self.app())

    def test_a_universal_bundle_with_its_notices_passes(self):
        def binary_tool(args, **kwargs):
            return "x86_64 arm64" if args[0] == "lipo" else "SwiftUI.framework AppKit.framework"
        with patch.object(bundle_check.subprocess, "check_output", side_effect=binary_tool):
            bundle_check.validate(self.app())


if __name__ == "__main__":
    unittest.main()
