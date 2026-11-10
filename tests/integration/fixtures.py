"""Process and filesystem fixtures for the real MTGO runtime specifications."""

from contextlib import contextmanager
from dataclasses import dataclass
from enum import IntEnum
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pwd
import shutil
import struct
import subprocess
import sys
import threading
import time
from typing import Optional


class Stage(IntEnum):
    """Wire values from MTGOSDK.Core.Remoting.LaunchStage."""

    CHECKING_FOR_UPDATES = 0
    VERIFYING_REQUIREMENTS = 1
    DOWNLOADING = 2
    UPDATE_COMPLETED = 3
    STARTING = 4
    STARTED = 5
    FAILED = 6


PE_MACHINES = {"arm64": 0xAA64, "x86_64": 0x8664}
DESKTOP_REFERENCE = "Magic The Gathering Online .appref-ms"


def progress_records(text):
    records = []
    for line in text.splitlines():
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and "stage" in record:
            records.append(record)
    return records


def pe_machine(image):
    with image.open("rb") as stream:
        stream.seek(0x3C)
        stream.seek(struct.unpack("<I", stream.read(4))[0])
        if stream.read(4) != b"PE\0\0":
            raise AssertionError(f"Not a PE image: {image}")
        return struct.unpack("<H", stream.read(2))[0]


@dataclass
class RunningClient:
    process: subprocess.Popen
    logs: Path
    environment: dict
    log_pattern: str = "session-*.log"
    observer: Optional[subprocess.Popen] = None
    game_started: bool = False

    @property
    def log_text(self):
        return "\n".join(file.read_text(errors="replace") for file in self.logs.glob(self.log_pattern))

    @property
    def native_log(self):
        return (self.logs / "native-app.log").read_text(errors="replace")

    def progress(self):
        deadline = time.monotonic() + 30
        while True:
            records = progress_records(self.log_text)
            if any(record.get("stage") == Stage.STARTED for record in records):
                return records
            if time.monotonic() > deadline:
                raise AssertionError("The SDK launcher did not report that MTGO started")
            time.sleep(1)

    def require_native_handoff(self):
        if self.observer is None:
            raise AssertionError("Native startup observer was not started")

        # Check macOS window visibility after Win32 startup and installation checks pass.
        (self.logs / "startup-complete").touch()
        status = self.observer.wait(timeout=15)
        if status != 0:
            output = (self.logs / "native-observer.log").read_text(errors="replace")
            raise AssertionError(f"Native startup observer exited with status {status}:\n{output}")


class ManifestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests += 1
        version = self.server.version
        body = json.dumps({"version": version} if version else {"error": "Unavailable"}).encode()
        self.send_response(200 if version else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class RuntimeDownloadHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests += 1
        if not self.server.available:
            self.send_error(503)
            return

        payload = self.server.payload
        size = payload.stat().st_size if isinstance(payload, Path) else len(payload)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        if isinstance(payload, Path):
            with payload.open("rb") as source:
                shutil.copyfileobj(source, self.wfile)
        else:
            self.wfile.write(payload)

    def log_message(self, *args):
        pass


class RuntimeFixture:
    """Runs each test session in a disposable Wine prefix."""

    def __init__(self, app, runtime, archive, win32_observer, native_observer, architecture="arm64"):
        self.architecture = architecture
        self.pe_machine = PE_MACHINES[architecture]
        self.app = app
        self.win32_observer = win32_observer
        self.native_observer = native_observer
        self.prefix = Path(os.environ["TEST_TMPDIR"]) / "Prefix"
        self.output = Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"])
        self.source_runtime = runtime
        self.runtime_root = runtime
        self.archive = archive
        self.runtime_cache = self.prefix.parent / "Runtimes"
        self.timeout = int(os.environ.get("MTGO_STARTUP_TIMEOUT", "600"))
        self.environment = dict(
            os.environ, WINEPREFIX=str(self.prefix), WINEARCH="win64", WINEDEBUG="-all",
            MTGO_PREFIX_ROOT=str(self.prefix), MTGO_WINEDEBUG="+macdrv",
            MTGO_RUNTIME_ROOT=str(runtime),
            MTGO_PACKAGE_CACHE=os.environ.get("MTGO_TEST_PACKAGE_CACHE", str(self.prefix.parent / "Packages")),
            DYLD_FALLBACK_LIBRARY_PATH=str(self.resources / "lib") + ":/usr/lib",
            PATH=str(self.resources / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
            WINEDLLOVERRIDES="winemenubuilder.exe=;d3d9=n",
        )
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "HODLL", "HODLL64"):
            self.environment.pop(name, None)

    @property
    def resources(self):
        return self.runtime_root / "MTGO.app/Contents/Resources"

    @property
    def wine(self):
        return self.resources / "bin/wine"

    @property
    def wineserver(self):
        return self.resources / "bin/wineserver"

    @contextmanager
    def runtime_downloads(self, *, payload=None, architecture=None):
        """Serve the exact release archive locally without publishing GitHub assets."""
        catalog = json.loads((self.app / "Contents/Resources/RuntimePackages.json").read_text())
        package = next(item for item in catalog["packages"] if item["architecture"] == self.architecture)
        architecture = architecture or self.architecture
        package["architecture"] = architecture
        catalog["packages"] = [package]
        server = ThreadingHTTPServer(("127.0.0.1", 0), RuntimeDownloadHandler)
        server.requests = 0
        server.available = True
        server.payload = self.archive if payload is None else payload
        package["url"] = f"http://127.0.0.1:{server.server_port}/{self.archive.name}"
        catalog_file = self.prefix.parent / "runtime-catalog.json"
        catalog_file.write_text(json.dumps(catalog))
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()

        previous_environment = self.environment.copy()
        previous_root = self.runtime_root
        self.runtime_root = self.runtime_cache / package["version"] / architecture
        self.environment.pop("MTGO_RUNTIME_ROOT", None)
        self.environment.update(
            MTGO_RUNTIME_CATALOG=str(catalog_file), MTGO_RUNTIME_CACHE=str(self.runtime_cache),
            DYLD_FALLBACK_LIBRARY_PATH=str(self.resources / "lib") + ":/usr/lib",
            PATH=str(self.resources / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
        )
        try:
            yield server
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)
            self.environment = previous_environment
            self.runtime_root = previous_root

    @property
    def profile(self):
        return self.prefix / "drive_c/users" / pwd.getpwuid(os.getuid()).pw_name

    @property
    def desktop(self):
        return self.profile / "Desktop"

    @property
    def user_data(self):
        return self.prefix.parent / "UserData"

    @property
    def installed_reference(self):
        return self.profile / "AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Daybreak Game Company LLC" / DESKTOP_REFERENCE

    @property
    def native_image_cache(self):
        suffix = "ARM64" if self.architecture == "arm64" else "64"
        return self.prefix / ("drive_c/windows/assembly/NativeImages_v4.0.30319_" + suffix)

    def run(self, *command, environment=None, timeout=600, check=True, log=None):
        arguments = [str(arg) for arg in command]
        environment = environment or self.environment
        if log is None:
            return subprocess.run(arguments, env=environment, check=check, timeout=timeout)

        with log.open("a") as output:
            return subprocess.run(arguments, env=environment, check=check, timeout=timeout,
                                  stdout=output, stderr=subprocess.STDOUT)

    def verify_bundle(self):
        self.run("/usr/bin/codesign", "--verify", "--deep", "--strict", self.app)
        self.run("/usr/bin/lipo", self.app / "Contents/MacOS/MTGO", "-verify_arch", self.architecture)

    @contextmanager
    def manifest_api(self):
        # Only the version API is controlled. ClickOnce downloads the real MTGO client.
        server = ThreadingHTTPServer(("127.0.0.1", 0), ManifestHandler)
        server.requests = 0
        server.version = None
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        previous = self.environment.get("MTGO_MANIFEST_URL")
        self.environment["MTGO_MANIFEST_URL"] = f"http://127.0.0.1:{server.server_port}/mtgo/manifest"
        try:
            yield server
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)
            if previous is None:
                self.environment.pop("MTGO_MANIFEST_URL", None)
            else:
                self.environment["MTGO_MANIFEST_URL"] = previous

    def native_arguments(self, *arguments):
        # Command-line defaults keep local preferences from changing the scenarios.
        preferences = ["-softwareRendering", "NO", "-animateTransitions", "YES", "-customIcon", ""]
        if "-userDataFolder" not in arguments:
            preferences += ["-userDataFolder", ""]
        if "-showStartupProgress" not in arguments:
            preferences += ["-showStartupProgress", "YES"]
        return ["/usr/bin/arch", "-" + self.architecture,
                self.app / "Contents/MacOS/MTGO", *arguments, *preferences]

    @contextmanager
    def start_app(self, scenario, *, arguments=(), environment=None, observe_game=False, expect_progress=True):
        logs = self.output / scenario
        logs.mkdir(parents=True)
        environment = {**self.environment, "MTGO_LOG_ROOT": str(logs), **(environment or {})}
        with (logs / "native-app.log").open("w") as log:
            process = subprocess.Popen(self.native_arguments(*arguments), env=environment,
                                       stdout=log, stderr=subprocess.STDOUT)
            client = RunningClient(process, logs, environment)
            try:
                if observe_game:
                    with (logs / "native-observer.log").open("w") as observer_log:
                        client.observer = subprocess.Popen(
                            [self.native_observer, str(process.pid), logs / "startup-complete", scenario, self.runtime_root]
                            + ([] if expect_progress else ["--hidden"]),
                            env=environment, stdout=observer_log, stderr=subprocess.STDOUT,
                        )
                yield client
            finally:
                self._stop(client)

    def require_visible_launcher_with_dock_entry(self, client):
        log = client.logs / "native-observer.log"
        result = self.run(self.native_observer, "--launcher", str(client.process.pid),
                          environment=client.environment, timeout=20, check=False, log=log)
        if result.returncode != 0:
            output = log.read_text(errors="replace")
            raise AssertionError(f"Launcher window observer exited with status {result.returncode}:\n{output}")

    def require_launch_failure(self, client, message):
        deadline = time.monotonic() + 20
        while message not in client.native_log:
            if client.process.poll() is not None or time.monotonic() > deadline:
                raise AssertionError(f"Launcher did not report: {message}")
            time.sleep(0.1)
        self.require_visible_launcher_with_dock_entry(client)

    def require_stable_mtgo(self, client):
        """Observe MTGO.exe's main window and matching CLR/JIT architecture for ten seconds."""
        # Framework setup restarts Wine, so launch the Win32 observer afterwards.
        deadline = time.monotonic() + 600
        while not (self.prefix / ".mtgo-framework.sha256").is_file():
            if "Could not start MTGO:" in client.native_log:
                raise AssertionError("Launcher preparation failed; see native-app.log")
            if client.process.poll() is not None or time.monotonic() > deadline:
                raise AssertionError("Framework preparation did not finish")
            time.sleep(1)
        self.run(self.wine, self.win32_observer, str(self.timeout),
                 environment=client.environment, timeout=self.timeout + 30,
                 log=client.logs / "win32-observer.log")
        client.game_started = True

    def prepare_legacy_desktop(self):
        self.desktop.rename(self.profile / "Desktop-before-migration")
        host = self.prefix.parent / "HostDesktop"
        host.mkdir()
        (host / "keep.txt").write_text("Unrelated desktop file")
        (host / DESKTOP_REFERENCE).write_bytes(self.installed_reference.read_bytes())
        self.desktop.symlink_to(host)
        return host

    def start_duplicate(self, client):
        with (client.logs / "duplicate-app.log").open("w") as log:
            return subprocess.run(self.native_arguments(), env=client.environment,
                                  stdout=log, stderr=subprocess.STDOUT, timeout=15)

    @contextmanager
    def start_offline_client(self):
        logs = self.output / "offline-fallback"
        logs.mkdir()
        environment = dict(self.environment, MTGO_LOG_ROOT=str(logs))
        with (logs / "launcher.log").open("w") as log:
            process = subprocess.Popen([
                self.wine, self.app / "Contents/Resources/Launcher/Launcher.exe",
                "--progress-json", "--start-and-wait", "http://127.0.0.1:9/MTGO.application",
            ], env=environment, stdout=log, stderr=subprocess.STDOUT)
            client = RunningClient(process, logs, environment, log_pattern="launcher.log")
            try:
                yield client
            finally:
                self._stop(client)

    def close_game(self, client):
        self.run(self.wine, "taskkill", "/IM", "MTGO.exe", "/F",
                 environment=client.environment, timeout=30, log=client.logs / "cleanup.log")
        return client.process.wait(timeout=30)

    def _stop(self, client):
        if client.observer is not None and client.observer.poll() is None:
            client.observer.terminate()
            client.observer.wait(timeout=10)
        if client.process.poll() is None:
            if client.game_started:
                # Let the SDK release its deployment store before stopping the prefix.
                self.run(self.wine, "taskkill", "/IM", "MTGO.exe", "/F",
                         environment=client.environment, timeout=30, check=False,
                         log=client.logs / "cleanup.log")
                try:
                    client.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    pass
            if client.process.poll() is None:
                client.process.terminate()
                client.process.wait(timeout=10)
        # Failed downloads and rejected releases must never initialize a Wine server.
        if not self.wineserver.exists() or not (Path(client.environment["WINEPREFIX"]) / "system.reg").exists():
            return

        # Let the server finish normally before forcing any remaining test processes down.
        try:
            self.run(self.wineserver, "-w", environment=client.environment,
                     timeout=10, log=client.logs / "cleanup.log")
        except subprocess.TimeoutExpired:
            self.run(self.wineserver, "-k", environment=client.environment,
                     timeout=30, log=client.logs / "cleanup.log")
            self.run(self.wineserver, "-w", environment=client.environment,
                     timeout=30, log=client.logs / "cleanup.log")

        for log in client.logs.glob("*.log"):
            if "wineserver crashed" in log.read_text(errors="replace"):
                raise AssertionError(f"WineServer crashed during {client.logs.name}; see {log}")

    def dump_logs(self):
        for file in self.output.rglob("*.log"):
            print("\n" + str(file) + ":", file=sys.stderr)
            print("\n".join(file.read_text(errors="replace").splitlines()[-40:]), file=sys.stderr)
