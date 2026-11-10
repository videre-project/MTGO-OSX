"""Release assets must keep the catalog, native archives and DMG together."""

import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from release import stage, verify


class ReleasePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "MTGO.app"
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "1.2.3",
        }))
        self.image = self.root / "dmg.dmg"
        self.image.write_bytes(b"The DMG produced by the build")
        self.output = self.root / "release"
        self.repository = "videre-project/MTGO-OSX"
        self.packages = []
        for architecture in ("arm64", "x86_64"):
            filename = f"runtime-0.4.0-macos-{architecture}.tar.xz"
            content = f"The {architecture} runtime archive".encode()
            (self.root / filename).write_bytes(content)
            self.packages.append({
                "version": "0.4.0", "architecture": architecture,
                "url": f"https://github.com/{self.repository}/releases/download/runtime-v0.4.0/{filename}",
                "sha256": hashlib.sha256(content).hexdigest(),
            })
        self.write_catalog()

    def write_catalog(self):
        (self.resources / "RuntimePackages.json").write_text(json.dumps({
            "schemaVersion": 1, "packages": self.packages,
        }))

    def stage_release(self):
        stage(self.app, self.image, self.root, self.output, self.repository)

    def test_staging_preserves_the_tested_bytes_and_independent_versions(self):
        """App 1.2.3 can reference runtime 0.4.0 without renaming or modifying its archives."""
        self.stage_release()
        self.assertEqual(verify(self.output, "v1.2.3", self.repository), "runtime-v0.4.0")
        self.assertEqual((self.output / "MTGO-1.2.3.dmg").read_bytes(), self.image.read_bytes())
        self.assertEqual((self.output / "RuntimePackages.json").read_bytes(),
                         (self.resources / "RuntimePackages.json").read_bytes())
        for archive in self.root.glob("runtime-*.tar.xz"):
            self.assertEqual((self.output / archive.name).read_bytes(), archive.read_bytes())

    def test_a_runtime_mismatch_is_rejected_before_staging_any_assets(self):
        """A locally rebuilt archive cannot be uploaded under another build's pinned checksum."""
        (self.root / "runtime-0.4.0-macos-arm64.tar.xz").write_bytes(b"A different runtime build")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.stage_release()
        self.assertFalse(self.output.exists())

    def test_a_release_requires_both_architectures_and_matching_download_urls(self):
        """Missing Intel support and URLs targeting another release must fail before upload."""
        self.packages.pop()
        self.write_catalog()
        with self.assertRaisesRegex(ValueError, "exactly one ARM64 and one Intel"):
            self.stage_release()

        self.packages.append(dict(self.packages[0], architecture="x86_64"))
        self.write_catalog()
        with self.assertRaisesRegex(ValueError, "Runtime URL does not match"):
            self.stage_release()
        self.assertFalse(self.output.exists())

    def test_transferred_assets_must_match_the_release_tag_and_checksums(self):
        """A wrong tag or bytes changed after artifact transfer must prevent publication."""
        self.stage_release()
        with self.assertRaisesRegex(ValueError, "do not match the app tag"):
            verify(self.output, "v1.2.4", self.repository)

        for asset in self.output.iterdir():
            if asset.name == "SHA256SUMS":
                continue
            with self.subTest(asset=asset.name):
                original = asset.read_bytes()
                asset.write_bytes(original + b" ")
                try:
                    with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                        verify(self.output, "v1.2.3", self.repository)
                finally:
                    asset.write_bytes(original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
