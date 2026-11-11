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
                "url": f"https://github.com/{self.repository}/releases/download/v1.2.3/{filename}",
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
        verify(self.output, "v1.2.3", self.repository)
        self.assertEqual({file.name for file in self.output.iterdir()}, {
            "MTGO-1.2.3.dmg", "RuntimePackages.json", "SHA256SUMS",
            "runtime-0.4.0-macos-arm64.tar.xz", "runtime-0.4.0-macos-x86_64.tar.xz",
        })
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

    def test_a_release_requires_both_runtime_architectures(self):
        """A release missing either native runtime must fail before staging any files."""
        self.packages.pop()
        self.write_catalog()
        with self.assertRaisesRegex(ValueError, "exactly one ARM64 and one Intel"):
            self.stage_release()
        self.assertFalse(self.output.exists())

    def test_runtime_downloads_must_target_the_app_release(self):
        """A separate runtime tag or another app release would leave downloads pointing elsewhere."""
        original = self.packages[0]["url"]
        for tag in ("runtime-v0.4.0", "v1.2.4"):
            with self.subTest(tag=tag):
                self.packages[0]["url"] = original.replace("/v1.2.3/", f"/{tag}/")
                self.write_catalog()
                with self.assertRaisesRegex(ValueError, "Runtime URL does not target"):
                    self.stage_release()
                self.assertFalse(self.output.exists())

    def test_unverified_assets_cannot_be_included_in_an_upload(self):
        """Extra DMGs or runtimes must be rejected even when all expected files are valid."""
        self.stage_release()
        for filename in ("MTGO-9.9.9.dmg", "runtime-9.9.9-macos-arm64.tar.xz"):
            with self.subTest(filename=filename):
                extra = self.output / filename
                extra.write_bytes(b"An asset outside the verified build")
                try:
                    with self.assertRaisesRegex(ValueError, "unexpected or missing assets"):
                        verify(self.output, "v1.2.3", self.repository)
                finally:
                    extra.unlink()

    def test_transferred_assets_must_match_the_release_tag_and_checksums(self):
        """A wrong tag or bytes changed after artifact transfer must prevent publication."""
        self.stage_release()
        with self.assertRaisesRegex(ValueError, "Runtime URL does not target"):
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
