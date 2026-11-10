#!/usr/bin/env python3
"""Check runtime architectures and sign Mach-O files after Linux or macOS builds."""

import argparse
from pathlib import Path
import subprocess


def sign_runtime(app, architecture):
    signed = 0
    for file in app.rglob("*"):
        if file.is_symlink() or not file.is_file():
            continue
        with file.open("rb") as stream:
            magic = stream.read(4)
        if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
            continue

        # Linux install-name normalization invalidates the linker's ad-hoc signatures.
        subprocess.run(["/usr/bin/lipo", file, "-verify_arch", architecture], check=True)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", file], check=True)
        signed += 1
    if not signed:
        raise ValueError("The runtime does not contain any Mach-O binaries: " + str(app))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("architecture", choices=("arm64", "x86_64"))
    args = parser.parse_args()
    sign_runtime(args.app, args.architecture)
