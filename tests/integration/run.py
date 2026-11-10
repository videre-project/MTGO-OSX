#!/usr/bin/python3
"""Supply Bazel runfiles to the integration specifications."""

import os
from pathlib import Path
import sys
import unittest

runfiles = Path(os.environ["TEST_SRCDIR"]) / "%WORKSPACE%"
sys.dont_write_bytecode = True
sys.path.insert(0, str(runfiles / "tests/integration"))

from startup_test import LauncherWindowTests, MTGORuntimeTests
from fixtures import RuntimeFixture


def main():
    runtime = RuntimeFixture(
        app=(runfiles / "%APP%").resolve(),
        runtime=(runfiles / "%RUNTIME%").resolve(),
        archive=(runfiles / "%RUNTIME_ARCHIVE%").resolve(),
        architecture="%ARCHITECTURE%",
        win32_observer=runfiles / "%OBSERVER%",
        native_observer=runfiles / "%LAUNCHER_OBSERVER%",
    )
    case = LauncherWindowTests if "%LAUNCHER_ONLY%" == "true" else MTGORuntimeTests
    case.runtime = runtime

    try:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(case)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    except Exception:
        runtime.dump_logs()
        raise
    if not result.wasSuccessful():
        runtime.dump_logs()
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
