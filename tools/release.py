#!/usr/bin/env python3
"""Transfer build outputs and package versioned macOS releases without recompiling."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

from copy_tree import copy_tree


def checksum(file):
    digest = hashlib.sha256()
    with file.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def release_version(tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("App release tags must use v<major>.<minor>.<patch>")
    return tag[1:]


def runtime_assets(catalog, repository, app_version):
    """Require both runtime architectures and URLs targeting one app version."""
    if catalog.get("schemaVersion") != 1:
        raise ValueError("Unsupported runtime catalog schema")

    packages = catalog["packages"]
    if len(packages) != 2 or {item["architecture"] for item in packages} != {"arm64", "x86_64"}:
        raise ValueError("A release must include exactly one ARM64 and one Intel runtime")

    versions = {item["version"] for item in packages}
    if len(versions) != 1:
        raise ValueError("Runtime architectures must use matching versions")
    runtime_version = versions.pop()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", runtime_version):
        raise ValueError("Runtime versions must use major.minor.patch")

    assets = {}
    for package in packages:
        filename = f"runtime-{runtime_version}-macos-{package['architecture']}.tar.xz"
        expected = f"https://github.com/{repository}/releases/download/v{app_version}/{filename}"
        if package["url"] != expected:
            raise ValueError(f"Runtime URL does not target v{app_version}: {package['url']}")
        if not re.fullmatch(r"[0-9a-f]{64}", package["sha256"]):
            raise ValueError(f"Invalid SHA-256 for {filename}")
        assets[filename] = package["sha256"]
    return assets


def require_checksums(directory, assets):
    for filename, expected in assets.items():
        if checksum(directory / filename) != expected:
            raise ValueError(f"SHA-256 mismatch: {filename}")


def write_checksums(directory):
    files = sorted(file for file in directory.rglob("*") if file.is_file() and file.name != "SHA256SUMS")
    (directory / "SHA256SUMS").write_text("".join(
        f"{checksum(file)}  {file.relative_to(directory).as_posix()}\n" for file in files
    ))


def verify_checksums(directory, expected_files=None):
    records = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        digest, filename = line.split("  ", 1)
        if filename in records:
            raise ValueError(f"Duplicate checksum entry: {filename}")
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"Invalid SHA-256 for {filename}")
        records[filename] = digest

    files = {file.relative_to(directory).as_posix() for file in directory.rglob("*") if file.is_file()}
    if (expected_files is not None and set(records) != expected_files) or files != set(records) | {"SHA256SUMS"}:
        raise ValueError("Artifact directory contains unexpected or missing assets")
    require_checksums(directory, records)
    return set(records)


def stage(app, artwork, runtimes, output, repository):
    """Archive the app and DMG inputs after build CI passes."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    catalog = app / "Contents/Resources/RuntimePackages.json"
    assets = runtime_assets(json.loads(catalog.read_text()), repository, info["CFBundleShortVersionString"])
    require_checksums(runtimes, assets)

    # Check inputs before creating an output directory that CI could upload.
    for file in [artwork / "background.tiff", artwork / "layout.json"]:
        if not file.is_file():
            raise ValueError(f"Missing DMG input: {file}")
    if not list((artwork / "wheels").glob("*.whl")):
        raise ValueError("Missing DMG packaging wheels")

    output.mkdir(parents=True, exist_ok=False)
    with tarfile.open(output / "MTGO.app.tar.gz", "w:gz", format=tarfile.PAX_FORMAT) as archive:
        archive.add(app.resolve(), arcname="MTGO.app")
    shutil.copytree(artwork, output / "dmg")
    shutil.copyfile(catalog, output / "RuntimePackages.json")
    for filename in assets:
        shutil.copyfile(runtimes / filename, output / filename)
    write_checksums(output)


def verify_build(directory, repository):
    """Verify every transferred input before extracting or changing the app."""
    files = verify_checksums(directory)
    with tarfile.open(directory / "MTGO.app.tar.gz", "r:gz") as archive:
        with archive.extractfile("MTGO.app/Contents/Info.plist") as stream:
            version = plistlib.load(stream)["CFBundleShortVersionString"]
    catalog = json.loads((directory / "RuntimePackages.json").read_text())
    assets = runtime_assets(catalog, repository, version)
    wheels = {file.relative_to(directory).as_posix() for file in (directory / "dmg/wheels").glob("*.whl")}
    if not wheels:
        raise ValueError("Missing DMG packaging wheels")
    expected = set(assets) | wheels | {
        "MTGO.app.tar.gz", "RuntimePackages.json", "dmg/background.tiff", "dmg/layout.json",
    }
    if files != expected:
        raise ValueError("Build artifacts contain unexpected or missing assets")
    require_checksums(directory, assets)
    return assets


def stamp(app, tag, build_number, repository):
    """Set release metadata on a working copy while retaining compiled files."""
    version = release_version(tag)
    if not re.fullmatch(r"[1-9][0-9]*", build_number):
        raise ValueError("Build numbers must be positive integers")

    info_path = app / "Contents/Info.plist"
    catalog_path = app / "Contents/Resources/RuntimePackages.json"
    info = plistlib.loads(info_path.read_bytes())
    catalog = json.loads(catalog_path.read_text())
    runtime_assets(catalog, repository, info["CFBundleShortVersionString"])

    # App release URLs change; runtime versions, filenames and hashes do not.
    for package in catalog["packages"]:
        filename = f"runtime-{package['version']}-macos-{package['architecture']}.tar.xz"
        package["url"] = f"https://github.com/{repository}/releases/download/{tag}/{filename}"
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = build_number
    info_path.write_bytes(plistlib.dumps(info))
    catalog_path.write_text(json.dumps(catalog, indent=2) + "\n")


def package(directory, tag, build_number, output, repository, identity="-"):
    """Stamp and sign an app from build CI, then create its release DMG."""
    version = release_version(tag)
    assets = verify_build(directory, repository)
    if output.exists():
        raise ValueError(f"Output directory already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="mtgo-release-", dir=output.parent) as temporary:
        work = Path(temporary)
        extracted = work / "build"
        extracted.mkdir()
        subprocess.run(["/usr/bin/tar", "-xzf", str((directory / "MTGO.app.tar.gz").resolve()), "-C", str(extracted)], check=True)
        source = extracted / "MTGO.app"
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)], check=True)
        if (source / "Contents/Resources/RuntimePackages.json").read_bytes() != (directory / "RuntimePackages.json").read_bytes():
            raise ValueError("Archived app does not match its runtime catalog")

        # Bazel outputs can be read-only. Change only an extracted working copy.
        app = work / "MTGO.app"
        copy_tree(source, app, writable=True)
        stamp(app, tag, build_number, repository)
        subprocess.run([
            "/usr/bin/codesign", "--force", "--sign", identity,
            "--preserve-metadata=entitlements,flags,runtime", "--timestamp=none", str(app),
        ], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)

        release = work / "release"
        release.mkdir()
        command = [sys.executable, str(Path(__file__).with_name("dmg.py")), "--app", str(app),
                   "--artwork", str(directory / "dmg"), "--output", str(release / f"MTGO-{version}.dmg")]
        for wheel in sorted((directory / "dmg/wheels").glob("*.whl")):
            command.extend(["--wheel", str(wheel)])
        subprocess.run(command, check=True)
        shutil.copyfile(app / "Contents/Resources/RuntimePackages.json", release / "RuntimePackages.json")
        for filename in assets:
            shutil.copyfile(directory / filename, release / filename)
        write_checksums(release)
        verify(release, tag, repository)
        release.rename(output)


def verify(directory, tag, repository):
    version = release_version(tag)
    catalog = json.loads((directory / "RuntimePackages.json").read_text())
    assets = runtime_assets(catalog, repository, version)
    verify_checksums(directory, set(assets) | {f"MTGO-{version}.dmg", "RuntimePackages.json"})
    require_checksums(directory, assets)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="videre-project/MTGO-OSX")
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("stage", help="Archive app, runtimes and DMG inputs from build CI")
    prepare.add_argument("--app", type=Path, default=Path("bazel-bin/src/MTGO.app"))
    prepare.add_argument("--artwork", type=Path, default=Path("bazel-bin/dmg.inputs"))
    prepare.add_argument("--runtimes", type=Path, default=Path("bazel-bin/src"))
    prepare.add_argument("--output", type=Path, required=True)
    assemble = commands.add_parser("package", help="Apply a release tag, sign the app and create its DMG")
    assemble.add_argument("--directory", type=Path, required=True)
    assemble.add_argument("--tag", required=True)
    assemble.add_argument("--build-number", required=True)
    assemble.add_argument("--output", type=Path, required=True)
    assemble.add_argument("--identity", default="-")
    check = commands.add_parser("verify", help="Verify final release assets before publication")
    check.add_argument("--directory", type=Path, required=True)
    check.add_argument("--tag", required=True)
    args = parser.parse_args()

    try:
        if args.command == "stage":
            stage(args.app, args.artwork, args.runtimes, args.output, args.repository)
        elif args.command == "package":
            package(args.directory, args.tag, args.build_number, args.output, args.repository, args.identity)
        else:
            verify(args.directory, args.tag, args.repository)
    except (ValueError, KeyError, OSError, tarfile.TarError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release preparation failed: {error}\n")


if __name__ == "__main__":
    main()
