#!/usr/bin/env python3
"""Package the app with generated artwork and Finder layout using pinned dmgbuild."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--artwork", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--wheel", action="append", required=True)
    args = parser.parse_args()
    # Bazel verifies these pure-Python wheels against sources.lock.json.
    sys.path[:0] = args.wheel
    from dmgbuild import build_dmg

    app = args.app.resolve()
    artwork = args.artwork.resolve()
    settings = json.loads((artwork / "layout.json").read_text())

    def verify_app(mount_point, _settings):
        installed = Path(mount_point) / app.name
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(installed)], check=True)

    settings.update(
        create_hook=verify_app,
        format="UDZO",
        files=[str(app)],
        symlinks={"Applications": "/Applications"},
        icon=str(app / "Contents/Resources/GameIcon.icns"),
        background=str(artwork / "background.tiff"),
    )
    build_dmg(str(args.output.resolve()), "MTGO", settings=settings)
    subprocess.run(["/usr/bin/hdiutil", "verify", "-quiet", str(args.output)], check=True)


if __name__ == "__main__":
    main()
