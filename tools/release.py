#!/usr/bin/env python3
"""Stage and verify the exact app and runtime assets produced by one build."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil


def checksum(file):
    digest = hashlib.sha256()
    with file.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def runtime_assets(catalog, repository, app_version):
    """Require both runtime architectures and URLs targeting the app release."""
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


def stage(app, image, runtimes, output, repository):
    with (app / "Contents/Info.plist").open("rb") as stream:
        version = plistlib.load(stream)["CFBundleShortVersionString"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("App versions must use major.minor.patch")

    catalog = app / "Contents/Resources/RuntimePackages.json"
    assets = runtime_assets(json.loads(catalog.read_text()), repository, version)
    require_checksums(runtimes, assets)

    # Validate the entire input set before writing a new release directory.
    files = {filename: runtimes / filename for filename in assets}
    files.update({f"MTGO-{version}.dmg": image, "RuntimePackages.json": catalog})
    hashes = {filename: checksum(source) for filename, source in files.items()}
    output.mkdir(parents=True, exist_ok=False)
    for filename, source in files.items():
        shutil.copyfile(source, output / filename)
    (output / "SHA256SUMS").write_text("".join(
        f"{hashes[filename]}  {filename}\n" for filename in sorted(files)
    ))


def verify(directory, tag, repository):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("App release tags must use v<major>.<minor>.<patch>")

    catalog = json.loads((directory / "RuntimePackages.json").read_text())
    assets = runtime_assets(catalog, repository, tag[1:])
    require_checksums(directory, assets)

    # Check the artifact transfer as well as the runtime hashes pinned by the app.
    expected_files = set(assets) | {f"MTGO-{tag[1:]}.dmg", "RuntimePackages.json"}
    records = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        digest, filename = line.split("  ", 1)
        if filename in records:
            raise ValueError(f"Duplicate checksum entry: {filename}")
        records[filename] = digest
    if set(records) != expected_files:
        raise ValueError("Release assets do not match the app tag and runtime catalog")
    if {file.name for file in directory.iterdir()} != expected_files | {"SHA256SUMS"}:
        raise ValueError("Release directory contains unexpected or missing assets")
    require_checksums(directory, records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="videre-project/MTGO-OSX")
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("stage", help="Copy verified build outputs without rebuilding or re-signing")
    prepare.add_argument("--app", type=Path, default=Path("bazel-bin/src/MTGO.app"))
    prepare.add_argument("--image", type=Path, default=Path("bazel-bin/dmg.dmg"))
    prepare.add_argument("--runtimes", type=Path, default=Path("bazel-bin/src"))
    prepare.add_argument("--output", type=Path, required=True)
    check = commands.add_parser("verify", help="Verify a transferred release before uploading assets")
    check.add_argument("--directory", type=Path, required=True)
    check.add_argument("--tag", required=True)
    args = parser.parse_args()

    try:
        if args.command == "stage":
            stage(args.app, args.image, args.runtimes, args.output, args.repository)
        else:
            verify(args.directory, args.tag, args.repository)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"Release verification failed: {error}\n")


if __name__ == "__main__":
    main()
