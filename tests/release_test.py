"""Release packaging changes metadata while retaining app code and runtime archives."""

import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from release import stage, stamp, verify, verify_build, write_checksums


class ReleasePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "MTGO.app"
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.videreproject.MTGOOSX",
            "CFBundleShortVersionString": "0.0.0", "CFBundleVersion": "0",
        }))
        binary = self.app / "Contents/MacOS/MTGO"
        binary.parent.mkdir()
        binary.write_bytes(b"Compiled universal launcher")
        binary.chmod(0o755)
        (self.resources / "Launcher.exe").write_bytes(b"Compiled SDK launcher")
        (self.resources / "launcher-link").symlink_to("Launcher.exe")

        self.artwork = self.root / "dmg"
        (self.artwork / "wheels").mkdir(parents=True)
        (self.artwork / "background.tiff").write_bytes(b"Retina artwork")
        (self.artwork / "layout.json").write_text('{"icon_size": 112}')
        (self.artwork / "wheels/dmgbuild.whl").write_bytes(b"Pinned packaging dependency")
        self.output = self.root / "build"
        self.repository = "videre-project/MTGO-OSX"
        self.packages = []
        for architecture in ("arm64", "x86_64"):
            filename = f"runtime-0.4.0-macos-{architecture}.tar.xz"
            content = f"The {architecture} runtime archive".encode()
            (self.root / filename).write_bytes(content)
            self.packages.append({
                "version": "0.4.0", "architecture": architecture,
                "url": f"https://github.com/{self.repository}/releases/download/v0.0.0/{filename}",
                "sha256": hashlib.sha256(content).hexdigest(),
            })
        self.write_catalog()

    def write_catalog(self):
        (self.resources / "RuntimePackages.json").write_text(json.dumps({
            "schemaVersion": 1, "packages": self.packages,
        }))

    def stage_build(self):
        stage(self.app, self.artwork, self.root, self.output, self.repository)

    def create_release(self):
        """Provide final assets for the publication verifier, without invoking macOS tools."""
        stamp(self.app, "v1.2.3", "42", self.repository)
        release = self.root / "release"
        release.mkdir()
        (release / "MTGO-1.2.3.dmg").write_bytes(b"Final signed app disk image")
        (release / "RuntimePackages.json").write_bytes((self.resources / "RuntimePackages.json").read_bytes())
        for archive in self.root.glob("runtime-*.tar.xz"):
            (release / archive.name).write_bytes(archive.read_bytes())
        write_checksums(release)
        return release

    def test_build_transfer_preserves_code_permissions_links_and_runtime_bytes(self):
        """Build artifacts retain the executable and packaging inputs for a later tag."""
        self.stage_build()
        verify_build(self.output, self.repository)
        with tarfile.open(self.output / "MTGO.app.tar.gz") as archive:
            binary = archive.getmember("MTGO.app/Contents/MacOS/MTGO")
            self.assertEqual(binary.mode & 0o777, 0o755)
            self.assertEqual(archive.extractfile(binary).read(), b"Compiled universal launcher")
            link = archive.getmember("MTGO.app/Contents/Resources/launcher-link")
            self.assertTrue(link.issym())
            self.assertEqual(link.linkname, "Launcher.exe")
        self.assertEqual((self.output / "dmg/background.tiff").read_bytes(), b"Retina artwork")
        for archive in self.root.glob("runtime-*.tar.xz"):
            self.assertEqual((self.output / archive.name).read_bytes(), archive.read_bytes())

    def test_a_release_tag_changes_only_plist_and_catalog_metadata(self):
        """Tag 1.2.3 can use runtime 0.4.0 without changing compiled app files."""
        before = {file.relative_to(self.app): file.read_bytes() for file in self.app.rglob("*") if file.is_file()}
        stamp(self.app, "v1.2.3", "42", self.repository)
        after = {file.relative_to(self.app): file.read_bytes() for file in self.app.rglob("*") if file.is_file()}
        self.assertEqual({path for path in before if before[path] != after[path]}, {
            Path("Contents/Info.plist"), Path("Contents/Resources/RuntimePackages.json"),
        })
        info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleShortVersionString"], "1.2.3")
        self.assertEqual(info["CFBundleVersion"], "42")
        self.assertEqual(info["CFBundleIdentifier"], "org.videreproject.MTGOOSX")
        catalog = json.loads((self.resources / "RuntimePackages.json").read_text())
        for original, package in zip(self.packages, catalog["packages"]):
            self.assertEqual(package["version"], "0.4.0")
            self.assertEqual(package["sha256"], original["sha256"])
            filename = f"runtime-0.4.0-macos-{package['architecture']}.tar.xz"
            self.assertEqual(package["url"], f"https://github.com/{self.repository}/releases/download/v1.2.3/{filename}")

    def test_invalid_tags_and_build_numbers_cannot_modify_the_app(self):
        """Invalid release inputs fail before writing either metadata file."""
        original_info = (self.app / "Contents/Info.plist").read_bytes()
        original_catalog = (self.resources / "RuntimePackages.json").read_bytes()
        for tag, build in [("1.2.3", "42"), ("v1.2", "42"), ("v1.2.3/other", "42"), ("v1.2.3", "0"), ("v1.2.3", "-1")]:
            with self.subTest(tag=tag, build=build):
                with self.assertRaises(ValueError):
                    stamp(self.app, tag, build, self.repository)
                self.assertEqual((self.app / "Contents/Info.plist").read_bytes(), original_info)
                self.assertEqual((self.resources / "RuntimePackages.json").read_bytes(), original_catalog)

    def test_a_runtime_mismatch_is_rejected_before_staging_any_assets(self):
        """A rebuilt runtime cannot be transferred under another build's pinned checksum."""
        (self.root / "runtime-0.4.0-macos-arm64.tar.xz").write_bytes(b"A different runtime build")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.stage_build()
        self.assertFalse(self.output.exists())

    def test_a_build_requires_both_runtime_architectures(self):
        """A missing native runtime fails before creating an upload directory."""
        self.packages.pop()
        self.write_catalog()
        with self.assertRaisesRegex(ValueError, "exactly one ARM64 and one Intel"):
            self.stage_build()
        self.assertFalse(self.output.exists())

    def test_source_catalog_urls_must_match_the_app_being_archived(self):
        """An unrelated release or repository cannot supply runtime downloads."""
        original = self.packages[0]["url"]
        for url in [original.replace("/v0.0.0/", "/v1.2.4/"), original.replace(self.repository, "other/project")]:
            with self.subTest(url=url):
                self.packages[0]["url"] = url
                self.write_catalog()
                with self.assertRaisesRegex(ValueError, "Runtime URL does not target"):
                    self.stage_build()
                self.assertFalse(self.output.exists())

    def test_every_build_input_is_verified_before_extraction(self):
        """Changed app archives, runtimes, artwork and wheels stop packaging."""
        self.stage_build()
        for asset in self.output.rglob("*"):
            if not asset.is_file() or asset.name == "SHA256SUMS":
                continue
            with self.subTest(asset=asset.relative_to(self.output)):
                original = asset.read_bytes()
                asset.write_bytes(original + b" ")
                try:
                    with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                        verify_build(self.output, self.repository)
                finally:
                    asset.write_bytes(original)

    def test_final_assets_match_the_release_tag_and_preserve_runtime_archives(self):
        """Publication accepts the stamped version with original runtime bytes."""
        release = self.create_release()
        verify(release, "v1.2.3", self.repository)
        self.assertEqual({file.name for file in release.iterdir()}, {
            "MTGO-1.2.3.dmg", "RuntimePackages.json", "SHA256SUMS",
            "runtime-0.4.0-macos-arm64.tar.xz", "runtime-0.4.0-macos-x86_64.tar.xz",
        })
        for archive in self.root.glob("runtime-*.tar.xz"):
            self.assertEqual((release / archive.name).read_bytes(), archive.read_bytes())
        with self.assertRaisesRegex(ValueError, "Runtime URL does not target"):
            verify(release, "v1.2.4", self.repository)

    def test_unlisted_or_unexpected_assets_cannot_be_published(self):
        """Adding a checksum does not make an unrelated DMG a release asset."""
        release = self.create_release()
        extra = release / "MTGO-9.9.9.dmg"
        extra.write_bytes(b"An unrelated app")
        with self.assertRaisesRegex(ValueError, "unexpected or missing assets"):
            verify(release, "v1.2.3", self.repository)
        write_checksums(release)
        with self.assertRaisesRegex(ValueError, "unexpected or missing assets"):
            verify(release, "v1.2.3", self.repository)

    def test_changed_final_assets_cannot_be_published(self):
        """Artifact transfer between packaging and publication must preserve every byte."""
        release = self.create_release()
        for asset in release.iterdir():
            if asset.name == "SHA256SUMS":
                continue
            with self.subTest(asset=asset.name):
                original = asset.read_bytes()
                asset.write_bytes(original + b" ")
                try:
                    with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                        verify(release, "v1.2.3", self.repository)
                finally:
                    asset.write_bytes(original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
