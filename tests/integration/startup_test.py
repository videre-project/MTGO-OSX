"""Integration tests for the native MTGO runtimes.

Local servers supply the version endpoint and runtime archive. Tests run the
actual MTGO client and ClickOnce installer, reusing one installation across
fresh, cached and offline launches.

Startup requires a stable main window with CLR/JIT modules matching the runtime
architecture. Responsiveness, rendered pixels, login and gameplay require manual
validation. Each fixture shuts down its test prefix and fails if WineServer
reports a crash.
"""

import json
import re
import unittest

from fixtures import DESKTOP_REFERENCE, RuntimeFixture, Stage, pe_machine, progress_records


class LauncherWindowTests(unittest.TestCase):
    runtime: RuntimeFixture

    def test_launcher_opens_centered_with_a_dock_entry(self):
        """The native startup window appears centered in its display's usable area."""
        self.runtime.verify_bundle()
        with self.runtime.start_app("launcher", arguments=("--preview",), environment={
            "MTGO_MANIFEST_URL": "file:///unavailable",
        }) as client:
            self.runtime.require_centered_launcher_with_dock_entry(client)


class MTGORuntimeTests(unittest.TestCase):
    runtime: RuntimeFixture

    def test_incompatible_runtime_is_rejected_before_wine_initializes(self):
        """An incompatible Dock protocol reports an error before Wine initializes its prefix."""
        runtime = self.runtime
        incompatible = runtime.prefix.parent / "IncompatibleRuntime"
        rejected_prefix = runtime.prefix.parent / "RejectedPrefix"
        incompatible.mkdir()
        manifest = json.loads((runtime.source_runtime / "runtime.json").read_text())
        manifest["dockProtocolVersion"] = 4
        (incompatible / "runtime.json").write_text(json.dumps(manifest))

        with runtime.start_app("incompatible-runtime", arguments=("-showStartupProgress", "NO"), environment={
            "MTGO_RUNTIME_ROOT": str(incompatible),
            "MTGO_PREFIX_ROOT": str(rejected_prefix),
            "WINEPREFIX": str(rejected_prefix),
        }) as client:
            runtime.require_launch_failure(client, "incompatible with this launcher")
            self.assertFalse((rejected_prefix / "system.reg").exists(),
                             "Rejected runtimes must not initialize Wine")

    def test_fresh_install_cached_relaunch_and_offline_startup(self):
        """One installation must support first launch, current-version relaunch and offline activation."""
        self.runtime.verify_bundle()
        self.assertFalse((self.runtime.prefix / "system.reg").exists(),
                         "The installation scenario must start with a fresh prefix")

        self.assertFalse((self.runtime.app / "Contents/Resources/Runtime").exists(),
                         "The universal app must not bundle an architecture-specific runtime")
        with self.runtime.runtime_downloads() as downloads, self.runtime.manifest_api() as api:
            installed_version = self.assert_fresh_install_starts_when_version_api_is_unavailable(api)
            self.assertEqual(downloads.requests, 1, "First launch must fetch the native runtime once")
            self.assertTrue((self.runtime.runtime_root / ".archive.sha256").is_file())
            original_inf = self.runtime.source_runtime / "MTGO.app/Contents/Resources/share/wine/wine.inf"
            installed_inf = self.runtime.resources / "share/wine/wine.inf"
            self.assertEqual(installed_inf.stat().st_mtime_ns, original_inf.stat().st_mtime_ns,
                             "Archiving must preserve wine.inf's prefix-update timestamp")

            # A current local runtime must launch without contacting its release server.
            downloads.available = False
            api.version = installed_version
            self.assert_current_deployment_relaunches_without_installation(api)
            self.assertEqual(downloads.requests, 1, "Cached runtime must work while its server is offline")

            self.assert_installed_client_starts_without_provider_or_desktop_shortcut()

    def test_corrupt_runtime_download_does_not_initialize_wine(self):
        """A checksum mismatch leaves no installed runtime or initialized prefix."""
        runtime = self.runtime
        rejected = runtime.prefix.parent / "CorruptDownloadPrefix"
        with runtime.runtime_downloads(payload=b"Not the pinned runtime archive") as downloads:
            with runtime.start_app("corrupt-download", environment={
                "MTGO_PREFIX_ROOT": str(rejected), "WINEPREFIX": str(rejected),
                "MTGO_MANIFEST_URL": "file:///unavailable",
            }) as client:
                runtime.require_launch_failure(client, "SHA-256 mismatch")
                self.assertEqual(downloads.requests, 1)
                self.assertFalse(runtime.runtime_root.exists())
                self.assertFalse((rejected / "system.reg").exists())

    def test_unavailable_native_runtime_is_rejected_without_downloading(self):
        """A catalog missing the native release must not download or run another architecture."""
        runtime = self.runtime
        rejected = runtime.prefix.parent / "WrongArchitecturePrefix"
        other = "x86_64" if runtime.architecture == "arm64" else "arm64"
        with runtime.runtime_downloads(architecture=other) as downloads:
            with runtime.start_app("wrong-architecture", environment={
                "MTGO_PREFIX_ROOT": str(rejected), "WINEPREFIX": str(rejected),
                "MTGO_MANIFEST_URL": "file:///unavailable",
            }) as client:
                runtime.require_launch_failure(client, "does not include a runtime release for " + runtime.architecture)
                self.assertEqual(downloads.requests, 0)
                self.assertFalse((rejected / "system.reg").exists())

    def assert_fresh_install_starts_when_version_api_is_unavailable(self, api):
        """A version-API outage must still allow official installation and real startup."""
        runtime = self.runtime
        for folder in ("Documents", "Downloads", "Music", "Pictures", "Videos"):
            (runtime.profile / folder).mkdir(parents=True, exist_ok=True)
        runtime.user_data.mkdir()
        original_data = runtime.profile / "AppData/Local/Apps/2.0/Data"
        original_data.mkdir(parents=True)
        (original_data / "keep.txt").write_text("Existing user data")

        # Hiding routine progress must never hide installation work.
        with runtime.start_app("first-launch", arguments=(
            "-showStartupProgress", "NO", "-userDataFolder", str(runtime.user_data),
        ), observe_game=True) as client:
            runtime.require_stable_mtgo(client)
            reports = client.progress()

            self.assert_progress_order(reports, (
                Stage.CHECKING_FOR_UPDATES, Stage.VERIFYING_REQUIREMENTS, Stage.DOWNLOADING,
                Stage.UPDATE_COMPLETED, Stage.STARTING, Stage.STARTED,
            ))
            self.assertTrue(any(
                report.get("stage") == Stage.DOWNLOADING and report.get("totalBytes", 0) > 0
                and 0 <= report.get("percentage", -1) <= 100 for report in reports
            ), "Installation must report real download sizes and percentages")
            self.assertEqual(api.requests, 1, "A launch must make one version-API request")
            self.assert_launcher_and_runtime_diagnostics(client)
            self.assert_desktop_is_private_to_prefix()
            self.assert_user_data_is_accessible_outside_prefix()
            self.assert_framework_native_images_match_runtime()
            self.assert_metal_backend_is_selected(client)
            self.assert_original_splash_is_suppressed(client)

            # The macOS observer checks the shared Dock entry and expanding crossfade.
            client.require_native_handoff()
            return next(report["version"] for report in reversed(reports) if report.get("version"))

    def assert_current_deployment_relaunches_without_installation(self, api):
        """A matching API version must skip installation and preserve a migrated desktop."""
        runtime = self.runtime
        previous_desktop = runtime.prepare_legacy_desktop()

        with runtime.start_app("repeat-launch", arguments=(
            "-showStartupProgress", "NO", "-userDataFolder", str(runtime.user_data),
        ), observe_game=True, expect_progress=False) as client:
            runtime.require_stable_mtgo(client)
            reports = client.progress()

            self.assert_progress_order(reports, (Stage.CHECKING_FOR_UPDATES, Stage.STARTING, Stage.STARTED))
            self.assert_no_installation(reports)
            self.assertTrue(any(report.get("version") for report in reports),
                            "Cached launch must report its deployment version")
            self.assertEqual(api.requests, 2, "Each of the two launches must request the version once")

            # These assertions cover SDK diagnostics; they do not intercept provider traffic.
            self.assertIn("skipping the deployment-provider check", client.log_text)
            self.assertNotIn("Starting MTGO update check for", client.log_text)
            self.assertNotIn("MTGO download progress:", client.log_text)
            self.assertNotIn("Compiling assembly", client.log_text,
                             "Cached launch must not rerun Framework native-image compilation")
            self.assert_launcher_and_runtime_diagnostics(client, expected_windows=0)
            self.assert_framework_native_images_match_runtime()
            self.assert_desktop_is_private_to_prefix()
            self.assert_user_data_is_accessible_outside_prefix()
            self.assertFalse((previous_desktop / DESKTOP_REFERENCE).exists())
            self.assertEqual((previous_desktop / "keep.txt").read_text(), "Unrelated desktop file")
            self.assertEqual((runtime.desktop / DESKTOP_REFERENCE).read_bytes(),
                             runtime.installed_reference.read_bytes())
            self.assert_metal_backend_is_selected(client)
            self.assert_original_splash_is_suppressed(client)
            self.assert_duplicate_launch_keeps_the_existing_session(client)
            client.require_native_handoff()

    def assert_installed_client_starts_without_provider_or_desktop_shortcut(self):
        """The SDK must activate its cached deployment and exit after MTGO exits."""
        runtime = self.runtime
        (runtime.desktop / DESKTOP_REFERENCE).unlink()

        with runtime.start_offline_client() as client:
            runtime.require_stable_mtgo(client)
            self.assertEqual(runtime.close_game(client), 0,
                             "The SDK launcher must finish successfully after MTGO exits")
            reports = progress_records(client.log_text)
            self.assert_progress_order(reports, (Stage.CHECKING_FOR_UPDATES, Stage.STARTING, Stage.STARTED))
            self.assert_no_installation(reports)
            self.assertIn("update failed; starting the installed deployment", client.log_text)

    def assert_progress_order(self, reports, expected):
        stages = [Stage(report["stage"]) for report in reports]
        self.assertNotIn(Stage.FAILED, stages, "Startup must not report a failure")
        for stage in expected:
            self.assertIn(stage, stages, f"Missing startup stage: {stage.name}")
        positions = [stages.index(stage) for stage in expected]
        self.assertEqual(positions, sorted(positions), f"Startup stages are out of order: {stages}")

    def assert_no_installation(self, reports):
        stages = {Stage(report["stage"]) for report in reports}
        installation = {Stage.VERIFYING_REQUIREMENTS, Stage.DOWNLOADING, Stage.UPDATE_COMPLETED}
        self.assertFalse(stages & installation, f"Cached activation entered installation: {stages}")

    def assert_launcher_and_runtime_diagnostics(self, client, expected_windows=1):
        self.assertEqual(client.native_log.count("Presented MTGO launcher window."), expected_windows,
                         "Progress visibility must match the startup scenario")
        self.assertNotIn("You are running with the wrong page size", client.log_text)

    def assert_desktop_is_private_to_prefix(self):
        desktop = self.runtime.desktop
        self.assertTrue(desktop.is_dir())
        self.assertFalse(desktop.is_symlink(), "Wine must not link its desktop to the host desktop")
        self.assertTrue(desktop.resolve().is_relative_to(self.runtime.prefix.resolve()))

    def assert_user_data_is_accessible_outside_prefix(self):
        path = self.runtime.profile / "AppData/Local/Apps/2.0/Data"
        self.assertTrue(path.is_symlink(), "Wine must retain the original ClickOnce data path as a symlink")
        self.assertEqual(path.resolve(), self.runtime.user_data.resolve())
        self.assertEqual((self.runtime.user_data / "keep.txt").read_text(), "Existing user data")
        self.assertTrue(any(self.runtime.user_data.rglob("mtgo..tion_*")),
                        "The real ClickOnce deployment must write into the selected folder")

    def assert_framework_native_images_match_runtime(self):
        # File presence and architecture are checked here; loaded-image usage is not observed.
        for name in ("PresentationFramework.ni.dll", "WindowsBase.ni.dll", "System.Deployment.ni.dll"):
            images = list(self.runtime.native_image_cache.rglob(name))
            self.assertTrue(images, f"Missing Framework native image: {name}")
            for image in images:
                self.assertEqual(pe_machine(image), self.runtime.pe_machine,
                                 f"Wrong architecture in native image: {image}")
        self.assertTrue((self.runtime.prefix / ".mtgo-native-images.sha256").is_file())

    def assert_metal_backend_is_selected(self, client):
        packaged = self.runtime.resources / "lib/dxvk/d3d9.dll"
        installed = self.runtime.prefix / "drive_c/windows/system32/d3d9.dll"
        self.assertTrue(packaged.is_file(), "The default runtime must include DXVK D3D9")
        self.assertEqual(installed.read_bytes(), packaged.read_bytes())
        self.assertIn("DXVK:", client.log_text)
        self.assertRegex(client.log_text, r"Driver\s+: MoltenVK")

    def assert_original_splash_is_suppressed(self, client):
        suppressed = set(re.findall(r'deferring native window (\S+) title [^\n]*KickerWindow', client.log_text))
        ordered = set(re.findall(r'show_window win (\S+?)/', client.log_text))
        self.assertTrue(suppressed, "MTGO must create its original splash for this check to be meaningful")
        self.assertFalse(suppressed & ordered, "The original MTGO splash reached native window ordering")

    def assert_duplicate_launch_keeps_the_existing_session(self, client):
        sessions = set(client.logs.glob("session-*.log"))
        duplicate = self.runtime.start_duplicate(client)

        self.assertEqual(duplicate.returncode, 0)
        self.assertIsNone(client.process.poll(), "Duplicate launch stopped the existing owner")
        self.assertEqual(set(client.logs.glob("session-*.log")), sessions,
                         "Duplicate launch created another Wine session")
        self.assertNotIn("Presented MTGO launcher window.",
                         (client.logs / "duplicate-app.log").read_text())
