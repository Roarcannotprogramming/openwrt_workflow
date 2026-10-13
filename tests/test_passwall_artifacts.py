"""Reject firmware builds that omit Passwall's runtime dependencies."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


VERIFY = Path(__file__).parents[1] / "passwall" / "verify_artifacts.py"
REQUIRED = ("luci-app-passwall", "sing-box", "geoview", "v2ray-geoip", "v2ray-geosite")


class PasswallArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def verify(self, mode, *options):
        return subprocess.run(
            [sys.executable, str(VERIFY), mode, str(self.root), *options],
            text=True, capture_output=True,
        )

    def packages(self, extension, omit=None):
        separator = "_" if extension == "ipk" else "-"
        architecture = "_x86_64" if extension == "ipk" else ""
        for name in REQUIRED:
            if name != omit:
                (self.root / f"{name}{separator}1.2.3-r1{architecture}.{extension}").write_bytes(b"fixture")

    def manifest(self, name="firmware.manifest", omit=None):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(f"{package} - 1.2.3-r1\n" for package in REQUIRED if package != omit))

    def test_accepts_complete_ipk_and_apk_package_sets(self):
        for extension in ("ipk", "apk"):
            with self.subTest(extension=extension):
                self.packages(extension)
                result = self.verify("packages", "--format", extension)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_missing_package_aborts_before_image_build(self):
        for extension in ("ipk", "apk"):
            for package in REQUIRED:
                with self.subTest(extension=extension, missing=package):
                    for path in self.root.iterdir():
                        path.unlink()
                    self.packages(extension, omit=package)
                    result = self.verify("packages", "--format", extension)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(package, result.stderr)

    def test_wrong_format_and_similar_package_names_do_not_satisfy_dependency(self):
        self.packages("ipk")
        result = self.verify("packages", "--format", "apk")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("geoview", result.stderr)
        self.packages("apk", omit="geoview")
        (self.root / "geoview-tools-1.2.3-r1.apk").write_bytes(b"fixture")
        result = self.verify("packages", "--format", "apk")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("geoview", result.stderr)

    def test_empty_package_file_is_not_a_build_artifact(self):
        self.packages("apk")
        next(self.root.glob("geoview-*.apk")).write_bytes(b"")
        result = self.verify("packages", "--format", "apk")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("geoview", result.stderr)

    def test_complete_final_firmware_manifests_pass(self):
        self.manifest("bin/targets/x86/64/generic.manifest")
        self.manifest("bin/targets/x86/64/generic-efi.manifest")
        result = self.verify("manifests")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_missing_final_dependency_blocks_firmware_publication(self):
        self.manifest("complete.manifest")
        for package in REQUIRED:
            with self.subTest(missing=package):
                self.manifest("incomplete.manifest", omit=package)
                result = self.verify("manifests")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(package, result.stderr)
                self.assertIn("incomplete.manifest", result.stderr)

    def test_no_final_manifest_is_an_error(self):
        result = self.verify("manifests")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest", result.stderr.lower())

    def test_manifest_checks_exact_package_names(self):
        self.manifest(omit="geoview")
        with (self.root / "firmware.manifest").open("a") as stream:
            stream.write("geoview-tools - 1.2.3-r1\n")
        result = self.verify("manifests")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("geoview", result.stderr)


if __name__ == "__main__":
    unittest.main()
