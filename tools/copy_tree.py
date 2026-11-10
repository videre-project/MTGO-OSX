"""Copy Bazel inputs while retaining relative links within the packaged runtime."""

import os
from pathlib import Path
import shutil
import sys


def copy_tree(source, destination, *, writable=False):
    # Sandbox input links are absolute; the runtime's own links are relative.
    while source.is_symlink():
        target = os.readlink(source)
        if not os.path.isabs(target):
            destination.symlink_to(target)
            return
        source = Path(target)
    if source.is_dir():
        destination.mkdir(parents=True, exist_ok=True)
        for child in source.iterdir():
            copy_tree(child, destination / child.name, writable=writable)
        shutil.copystat(source, destination)
        if writable:
            destination.chmod(destination.stat().st_mode | 0o700)
    else:
        shutil.copy2(source, destination)
        if writable:
            destination.chmod(destination.stat().st_mode | 0o200)


if __name__ == "__main__":
    copy_tree(Path(sys.argv[1]), Path(sys.argv[2]))
