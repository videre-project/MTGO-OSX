# MTGO-OSX

MTGO-OSX runs Magic: The Gathering Online on macOS through Wine, with a native SwiftUI and AppKit launcher for installation, updates and startup. Distributed as a universal app, MTGO-OSX downloads a matching ARM64 or x86_64 runtime so Wine, .NET Framework 4.8.1 and MTGO run in the native architecture. Direct3D 9 rendering uses DXVK and MoltenVK to translate calls to Metal.

## Build and Run

Builds require an Apple silicon Mac with Apple's Command Line Tools or Xcode, the .NET 10 SDK and Rosetta. A universal build generates both runtime archives to record their hashes in the app, so it also builds Intel dependencies through Rosetta. Bazel is pinned in `.bazelversion`.

Compilation targets macOS 13. The oldest supported runtime OS still needs to be established through integration testing; see [macOS Compatibility](docs/runtime.md#macos-compatibility).

```sh
./bazelw build //:MTGO //:dmg
MTGO_RUNTIME_ROOT="$PWD/bazel-bin/src/runtime" ./bazelw run //:MTGO
./bazelw test //tests:mtgo_startup
```

Build outputs include `bazel-bin/src/MTGO.app` and `bazel-bin/dmg.dmg`. The app bundles a universal native launcher, the MTGOSDK ClickOnce launcher and branding, with Wine and graphics libraries downloaded separately. The development command above uses a locally built runtime, while integration tests serve an archive locally. Both work before GitHub release assets are published.

Runtime archives are built by `//:runtime_arm64` and `//:runtime_x86_64` at `bazel-bin/src/runtime-0.1.0-macos-<architecture>.tar.xz`. A `Contents/Resources/RuntimePackages.json` catalog in the app records their release URLs and SHA-256 hashes. Publish matching runtime assets before distributing the DMG, as described under [Releases](#releases).

The DMG opens in Finder with MTGO and an Applications shortcut over a Retina background matching the launcher. Artwork and Finder metadata are generated from pinned `dmgbuild` dependencies without Finder automation. Builds are ad-hoc signed; distribution signing and notarization remain separate release work.

## Project Layout

```text
docs/                                   Runtime architecture
src/
  Application.swift, AppDelegate.swift   App lifecycle and native menus
  Dock/                                 Wine window activation and Dock integration
  Launcher/
    UI/                                 Main layout, artwork, typography and progress bar
    Settings/                           Appearance, behavior and runtime preferences
    Activity/                           Activity history, rows and disclosure behavior
    LauncherSession.swift               Launch, stop and restart orchestration
    LauncherState.swift                 Session state and status text
    LauncherWindowController.swift      Native windows and game handoff animation
    MTGOManifest.swift                  Current-version lookup
    LaunchProgress.swift                MTGOSDK progress protocol
    StartupProgress.swift               Shared download and setup measurements
    SessionLock.swift                   One session per Wine prefix
  Runtime/
    Wine/                               Wine binaries, manifests, prefix and graphics setup
    Framework/                          .NET Framework installation, configuration and native images
    RuntimeArchitecture.swift           Binary formats and Framework layout
    RuntimePackage.swift                Native architecture and pinned release selection
    RuntimeInstaller.swift              Runtime download, verification and installation
    NativeProcess.swift                 Process execution, logging and stdout delivery
    VerifiedDownload.swift              Verified package cache
    BinaryArchitecture.swift            Executable header inspection
  Resources/                            Shared icons, artwork and fonts
tests/                                  Real-client integration and native behavior tests
third_party/<dependency>/               Dependency build recipe and local patches
tools/                                  Bazel rules, packaging and asset generation
```

Dependency recipes are organized by library under `third_party/`, with shared build rules in `third_party/native.bzl` and archive versions and hashes in `third_party/sources.lock.json`. MTGOSDK is pinned separately in `MODULE.bazel` as a NuGet package. Packaging extracts the published ClickOnce launcher and its dependency unchanged, keeping downloaded packages and compiled binaries outside source control.

### Where to Make Changes

| Change | Files |
| --- | --- |
| Launcher layout, spacing and buttons | [LauncherView.swift](src/Launcher/UI/LauncherView.swift) |
| Fonts, colors and background artwork | [LauncherTheme.swift](src/Launcher/UI/LauncherTheme.swift), [LauncherBackground.swift](src/Launcher/UI/LauncherBackground.swift) |
| Window placement and transition into MTGO | [LauncherWindowController.swift](src/Launcher/LauncherWindowController.swift) |
| Settings values and panel | [Launcher/Settings](src/Launcher/Settings) |
| Activity display, disclosure and elapsed times | [Launcher/Activity](src/Launcher/Activity) |
| Launch, cancellation and restart behavior | [LauncherSession.swift](src/Launcher/LauncherSession.swift) |
| Preparation statuses and activity messages | [LauncherSession.swift](src/Launcher/LauncherSession.swift): `reportPreparation`, `receiveProgress` |
| Progress bar, counts and download estimates | [StartupProgress.swift](src/Launcher/StartupProgress.swift), [StartupProgressBar.swift](src/Launcher/UI/StartupProgressBar.swift), [LauncherSession.swift](src/Launcher/LauncherSession.swift) |
| Status wording and SDK progress records | [LauncherState.swift](src/Launcher/LauncherState.swift), [LaunchProgress.swift](src/Launcher/LaunchProgress.swift) |
| Videre version check | [MTGOManifest.swift](src/Launcher/MTGOManifest.swift) |
| ClickOnce installation, updates and cached activation | [MTGOSDK](https://github.com/videre-project/MTGOSDK/tree/v1.9.0/MTGOSDK/lib/Launcher); [package extraction](third_party/mtgosdk) |
| Runtime release selection and download | [RuntimePackage.swift](src/Runtime/RuntimePackage.swift), [RuntimeInstaller.swift](src/Runtime/RuntimeInstaller.swift) |
| Wine prefix, rendering configuration and runtime validation | [Runtime/Wine](src/Runtime/Wine) |
| User-data folder and migration | [WineUserData.swift](src/Runtime/Wine/WineUserData.swift) |
| .NET Framework installation and optimization | [Runtime/Framework](src/Runtime/Framework) |
| Native menus and application lifecycle | [AppDelegate.swift](src/AppDelegate.swift) |
| Dock activation, window notifications and attention | [DockController.swift](src/Dock/DockController.swift), [DockAttentionView.swift](src/Dock/DockAttentionView.swift) |
| Wine's Mac driver and compatibility fixes | [third_party/wine](third_party/wine) |
| D3D9 and Metal translation | [third_party/dxvk](third_party/dxvk), [third_party/moltenvk](third_party/moltenvk) |
| App contents, signatures and runtime packaging | [macos.bzl](tools/macos.bzl) |
| DMG artwork and Finder layout | [dmg.swift](tools/dmg.swift), [dmg.py](tools/dmg.py) |

Application and runtime changes can be built separately. DXVK and Wine share a Windows cross compiler, but DXVK is not a Wine build dependency, so graphics backend changes do not require rebuilding Wine. MTGO-OSX's default Metal app and an optional OpenGL comparison app also use the same Wine build, allowing both rendering paths to be tested with the same compatibility patches.

## Launch Flow

On first launch, MTGO-OSX downloads a native runtime from the bundled catalog and verifies the archive hash, binary architecture, Dock protocol and helper app signature before installation. Later launches reuse that installation without contacting GitHub. Runtime releases are versioned separately from the MTGO client.

Windows files, registry data and installed applications are stored in a separate directory called a Wine prefix. Setup prepares this prefix with architecture-matched .NET Framework files downloaded from Microsoft, then uses the Native Image Generator (`ngen.exe`) to compile Framework assemblies before starting MTGO. This preparation is reused on later launches.

A version lookup runs against the [Videre manifest API](https://api.videreproject.com/mtgo/manifest) while runtime and prefix preparation proceed. MTGOSDK compares that version with the installed ClickOnce subscription and activates a current deployment without contacting the MTGO update provider. If an installation is missing or older, or the API is unavailable, startup follows the SDK update path. An installed deployment can still start if the provider check fails.

By default, the launcher covers installation, updates and the wait for the main game window, then transitions into MTGO. Progress and expandable activity groups show setup details; groups start collapsed so assembly output does not push later stages out of view. The version at the bottom reports MTGO's installed version when available, falling back to the latest version retrieved from Videre. It is separate from app and runtime release versions.

Setup and gameplay share one MTGO icon and Dock entry, even though the native UI and game windows run in separate processes. Wine runs as an accessory application so that entry can remain in place when the launcher gives way to the game. Clicking it restores the game window; reopening the app focuses the active session. Closing the main game window removes the Dock entry while the remaining shutdown work finishes in the background.

MTGO's original splash screen is hidden during startup. ClickOnce shortcuts stay inside the Wine prefix, with cached activation using a private Start Menu reference, so installation does not add shortcuts to the Mac desktop.

Hardware rendering is the default. Software rendering is available in Settings; foil treatments and other Shader Model 3 effects require hardware rendering. The optional OpenGL comparison app is `//:MTGO_opengl`.

Runtime downloads are installed under `~/Library/Application Support/MTGO-OSX/Runtimes/<version>/<architecture>`. New prefixes use `~/Library/Application Support/MTGO-OSX/Prefixes/<architecture>`; existing ARM64 installations under `Prefix` are retained. Package downloads are cached in `~/Library/Caches/MTGO-OSX/Packages`.

For diagnostics, choose **MTGO → Show Session Log** or use the document button in the launcher. Logs are stored under `~/Library/Application Support/MTGO-OSX/Logs`. See [Runtime Architecture](docs/runtime.md) for validation, Framework setup and session handling.

### Settings

Open **MTGO → Settings…** to change appearance, attention behavior and runtime options. Appearance includes a custom app icon and the startup transition; Behavior controls the attention badge and progress on routine launches. Installation, updates and errors remain visible when routine progress is disabled. Transitions and badge pulses also respect Reduce Motion in System Settings.

Custom images are copied to `~/Library/Application Support/MTGO-OSX/Icons`, so moving or deleting the original image does not affect the selection. The running Dock icon changes immediately; MTGO windows use it after restarting. Reset restores the bundled MTGO icon. Finder retains the installed app icon because customization does not modify the signed bundle.

Runtime shows the release version, native architecture, rendering selection and storage use. Runtime and Wine-prefix folder overrides are under Advanced. Changes that affect an active Wine session show a restart option; native preferences apply immediately.

Under User data, choose a Mac folder to store game history, settings and cached logs outside the prefix. A symbolic link preserves the ClickOnce path at `AppData/Local/Apps/2.0/Data`, including generated deployment and account subdirectories. Existing data is copied before the link changes; **Use Default Folder** copies it back into the prefix while retaining the external copy. Folder changes apply after restarting MTGO, and **Show in Finder** opens the selected location.

Choose an existing, writable folder outside the prefix. When moving existing data, the destination must be empty or match that data; differing stores are preserved and the change fails. A missing external folder also stops startup instead of creating an empty store. Reconnect it before relaunching or resetting to the default folder.

### Development Settings

Environment overrides apply to the current app instance without changing saved preferences or the bundled catalog:

| Variable | Purpose |
| --- | --- |
| `MTGO_PREFIX_ROOT` | Use a different Wine prefix. |
| `MTGO_RUNTIME_ROOT` | Use a local runtime instead of downloading one. |
| `MTGO_RUNTIME_CATALOG` | Read a local runtime catalog for download testing. |
| `MTGO_RUNTIME_CACHE` | Install downloaded runtimes in a different directory. |
| `MTGO_PACKAGE_CACHE` | Store verified runtime archives and Microsoft installer downloads in a different directory. |
| `MTGO_LOG_ROOT` | Write session logs to a different directory. |
| `MTGO_ICON_CACHE` | Store imported app icons in a different directory. |
| `MTGO_MANIFEST_URL` | Use a different MTGO version endpoint for integration testing. |
| `MTGO_WINEDEBUG` | Enable Wine diagnostic channels. |

`MTGO_RUNTIME_ROOT` takes precedence over automatic runtime selection. A custom `MTGO_RUNTIME_CATALOG` bypasses saved runtime-folder selections and bundled comparison runtimes, allowing a fixture catalog to exercise downloading. Runtime catalogs accept HTTPS release URLs and loopback HTTP for fixtures; manifests use the format in [runtime.json](src/Runtime/Wine/runtime.json).

To inspect the launcher without starting Wine or installing MTGO, run:

```sh
bazel-bin/src/MTGO.app/Contents/MacOS/MTGO --preview
```

## Integration Testing

Start with [the runtime specification](tests/integration/startup_test.py). It uses standard `unittest` assertions and names the expected behaviors:

- A launcher window opens centered with its Dock entry.
- Corrupt downloads and catalogs missing a native release fail before Wine starts.
- An incompatible Wine runtime is rejected before prefix initialization.
- A fresh launch downloads the real runtime archive and installs official MTGO even when the version API is unavailable.
- A later launch reuses that runtime while its download server is unavailable.
- A current deployment relaunches without installation, migrates its desktop shortcut safely and retains one native session when opened again.
- Cached activation works without the deployment provider or desktop shortcut, and the SDK launcher exits after MTGO exits.

A lifecycle scenario reuses one real installation across fresh, cached and offline launches. Progress stages are named in the spec rather than asserted as protocol integers. The scenario uses a local version API and runtime archive server while running the real ClickOnce installer and MTGO client.

The tests use separate observers because Win32 startup and macOS integration expose different information. A Win32 observer checks the main window and matching Common Language Runtime (CLR) and just-in-time (JIT) compiler modules over ten seconds; a native observer checks window placement, Dock behavior and the crossfade. Both run outside the app. Process control, disposable prefixes and logs are centralized in `tests/integration/fixtures.py`, with `run.py` providing the Bazel entry point.

`//tests:mtgo_startup` runs the ARM64 specification; `//tests:mtgo_startup_x86_64` runs it for Intel through Rosetta. The Intel target must be selected explicitly and is added to CI for tagged releases. Real-client tests require a logged-in macOS GUI session and internet access. Fixtures use disposable prefixes, retain logs under `bazel-testlogs`, and never accept MTGO's license agreement or enter account credentials. To reuse verified Framework packages, pass `--test_env=MTGO_TEST_PACKAGE_CACHE=/path/to/cache`.

`//tests:launcher_startup` checks the native launcher window. Other targets cover behavior that can be tested separately from a full MTGO installation:

| Target | Behavior |
| --- | --- |
| `//tests:dock_attention` | A Win32 fixture requests and stops attention, regains focus and closes its window. Native checks observe the indicator, animation and focus behavior through the packaged Wine driver. |
| `//tests:dock_attention_x86_64` | The same attention check with Intel Wine through Rosetta. |
| `//tests:settings` | Native preference panes, saved selections, icon import and reset, transition controls, and storage totals that exclude Wine links into host folders. Pane captures are retained in test outputs. |
| `//tests:preparation` | Framework component installation for both architectures, progress after successful writes, and user-data migration, reset, conflicting stores and unavailable folders. |

Attention and settings tests require a GUI session and run exclusively because they change foreground focus. Preparation tests use file fixtures without starting Wine. The real-client specification connects these checks to installation: it exercises download, extraction and NGen, starts ClickOnce with an external user-data folder, and verifies that hiding routine progress still permits setup and errors to appear.

Startup here means a stable main window with matching CLR/JIT architecture. Automated checks cover native window metadata and backend diagnostics; window responsiveness, rendered pixels, login and gameplay require manual validation. Provider-skip assertions inspect SDK diagnostics, and native-image assertions inspect generated files rather than proving those images were loaded.

Run the main CI test set locally with:

```sh
./bazelw test //tests:launcher_startup //tests:settings //tests:preparation \
  //tests:mtgo_startup //tests:dock_attention
```

On pushes to `main` and pull requests, the [build workflow](.github/workflows/build.yml) builds the app and DMG, runs release-packaging checks and the targets above, then uploads matching DMG, runtime archives, catalog and checksums as `MTGO-macos`. Test logs are uploaded separately, including after failures. Version tags run the same workflow with Intel lifecycle and attention tests added.

### Intel Testing

For manual Intel testing on Apple silicon, build the Intel-only launcher and use the local runtime until release assets are published:

```sh
./bazelw build //src:MTGO_intel
MTGO_RUNTIME_ROOT="$PWD/bazel-bin/src/runtime_intel" \
MTGO_PREFIX_ROOT="$HOME/Library/Application Support/MTGO-OSX/Prefixes/x86_64" \
  bazel-bin/src/MTGO_intel.app/Contents/MacOS/MTGO
```

This test bundle permits Rosetta. The universal distribution bundle requires native execution and selects its runtime accordingly. Rosetta testing does not establish compatibility with Intel GPUs.

## Releases

A push to `main` builds and tests without creating releases. Pushing an app tag such as `v0.1.0` starts the [release workflow](.github/workflows/release.yml), which runs the shared build and both runtime specifications before preparing draft GitHub releases for the app and runtime. Release assets are transferred from that build without rebuilding or re-signing them. These are development previews with ad-hoc signatures, without notarization or signing credentials.

App tags must match `CFBundleShortVersionString` in `src/Info.plist`. Runtime versions are declared by `RUNTIME_VERSION` in `src/BUILD.bazel`; changed archives need a new runtime version. The pipeline refuses to replace published app or runtime assets. An existing runtime release can be reused only when its catalog and archive bytes match the current build. Unpublished drafts can be refreshed by rerunning the workflow.

Review and publish the `runtime-v<version>` draft first, then the `v<version>` app draft. Draft assets are unavailable through the launcher's public download URLs. Users download `MTGO-<version>.dmg`; the architecture-specific runtime archives and `RuntimePackages.json` belong to the runtime release.

Release packaging can also be verified locally:

```sh
python3 -m unittest discover -s tests -p release_test.py -v
python3 tools/release.py stage --output dist
python3 tools/release.py verify --directory dist --tag v0.1.0
```

Use a new output directory for each staging run so earlier release assets cannot be included accidentally. Signing/notarization and updating the macOS app itself remain separate work; MTGO updates continue through the SDK's ClickOnce launcher.

## License

This project is licensed under the [Apache-2.0 License](LICENSE).

Third-party dependencies and assets retain their respective licenses and copyright notices.
