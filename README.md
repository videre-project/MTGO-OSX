# MTGO-OSX

**MTGO-OSX** is a native macOS launcher for installing and running **Magic: The Gathering Online (MTGO)**. It manages installation and updates with a custom ClickOnce launcher, and provides native macOS menus, graphics and macOS drivers, dock entries, and settings for MTGO.

MTGO runs under Wine with .NET Framework 4.8.1 natively on both Intel and Apple Silicon Macs with full CPU and GPU hardware acceleration. MTGO-OSX is distributed as a universal app that downloads Wine and graphics libraries during setup.

## Build and Run

To build MTGO-OSX, we recommend an Apple silicon Mac with Apple's Command Line Tools or Xcode, .NET 10 SDK and Rosetta installed. Bazel builds a universal app and separate Wine runtimes for ARM64 and x86_64, then records runtime download URLs and hashes in the app. Local Intel source builds use Rosetta; [Linux Runtime Builds](#linux-runtime-builds) explains how to compile both runtimes with Docker instead as we use in GitHub Actions CI.

MTGO-OSX requires macOS 13 (Ventura) or later; see [macOS Compatibility](docs/runtime.md#macos-compatibility).

```sh
./bazelw build //:MTGO //:dmg //:runtime_arm64
runtime_dir="$(mktemp -d)"
tar -xJf bazel-bin/src/runtime-0.1.0-macos-arm64.tar.xz -C "$runtime_dir"
MTGO_RUNTIME_ROOT="$runtime_dir" ./bazelw run //:MTGO
./bazelw test //tests:mtgo_startup
```

Bazel writes `bazel-bin/src/MTGO.app` and `bazel-bin/dmg.dmg`. MTGO-OSX includes a ClickOnce launcher from MTGOSDK for installing and activating MTGO. Wine and graphics libraries are packaged separately for download during setup.

For local development, `MTGO_RUNTIME_ROOT` selects a runtime extracted from a release archive, as shown above. Extracting an archive preserves Wine’s relative symlinks across Bazel cache restoration. Integration tests download runtime archives from a local HTTP server, so development and testing can proceed before publishing GitHub release assets.

Build `//:runtime_arm64` and `//:runtime_x86_64` to produce `bazel-bin/src/runtime-0.1.0-macos-<architecture>.tar.xz`. During app packaging, Bazel writes download URLs and SHA-256 hashes for these archives to `Contents/Resources/RuntimePackages.json`. Each GitHub release includes these archives and a matching DMG; see [Releases](#releases).

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
third_party/<dependency>/               Bazel definitions and upstream patches
tools/                                  Bazel rules, packaging and asset generation
```

Build definitions for Wine, graphics libraries and packaging tools are organized under `third_party/`, alongside any patches applied to upstream sources. These definitions use downloads pinned in [`third_party/sources.lock.json`](third_party/sources.lock.json), which records archive URLs and SHA-256 hashes. Bazel either compiles source code through shared rules in [`third_party/native.bzl`](third_party/native.bzl) or packages binaries from an upstream release.

The ClickOnce launcher comes from a published MTGOSDK NuGet package, pinned by version and SHA-256 hash in [`MODULE.bazel`](MODULE.bazel). During a build, Bazel runs [ExtractLauncher.cs](third_party/mtgosdk/ExtractLauncher.cs) to copy `Launcher.exe` from `MTGOSDK.dll` and `System.Deployment.dll` from the launcher's embedded resources. MTGO-OSX bundles both files unchanged for ClickOnce installation, updates and activation.

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
| App contents, signatures and runtime packaging | [macos.bzl](tools/macos.bzl), [sign_runtime.py](tools/sign_runtime.py) |
| Linux build jobs and incremental caches | [build.yml](.github/workflows/build.yml), [Dockerfile](tools/linux/Dockerfile) |
| Imported Wine archives | [native_artifacts.bzl](tools/native_artifacts.bzl), [native.bzl](third_party/native.bzl) |
| DMG artwork and Finder layout | [dmg.swift](tools/dmg.swift), [dmg.py](tools/dmg.py) |

Application and runtime changes can be built separately. DXVK D3D9 binaries are downloaded from a pinned MetalSharp release, with ARM64X and Intel packages selected for the corresponding runtime. Updating DXVK repackages the runtime without rebuilding Wine. MTGO-OSX's default Metal app and an optional OpenGL comparison app use the same Wine build, allowing both rendering paths to be tested with the same compatibility patches.

### Linux Runtime Builds

The [Linux build image](tools/linux/Dockerfile) includes Clang, OSXCross and build utilities for compiling ARM64 and x86_64 macOS binaries. Building this image also requires a macOS SDK and Darwin compiler runtime from Apple developer tools, supplied through named Docker build contexts. OSXCross uses ld64 to link GMP's optimized Intel assembly, which contains relocations unsupported by LLVM's Mach-O linker.

Create a builder with explicit CPU and memory limits, and finish building the image before compiling Wine. The commands below use limits suitable for a Docker VM with 4 GB of RAM. Bazel action scheduling and compiler parallelism are configured separately.

```sh
docker buildx create --name mtgo-osx-cross --driver docker-container \
  --driver-opt memory=2g --driver-opt cpu-period=100000 --driver-opt cpu-quota=200000
docker buildx build --builder mtgo-osx-cross --load -t mtgo-osx-cross \
  --build-context macos_sdk="$(xcrun --sdk macosx --show-sdk-path)" \
  --build-context compiler_rt="$(xcrun clang -print-resource-dir)/lib/darwin" \
  tools/linux
docker buildx stop mtgo-osx-cross
```

To build both Wine architectures, mount this repository read-only and use a named volume for downloads and build outputs. One Bazel action runs at a time, with two compiler jobs. Unsigned Wine archives are copied back to macOS after compilation finishes.

```sh
docker volume create mtgo-osx-cross-build
docker run --name mtgo-osx-runtime-build --cpus=2 --memory=2304m --memory-swap=2304m \
  --mount "type=bind,source=$PWD,target=/workspace,readonly" \
  --mount type=volume,source=mtgo-osx-cross-build,target=/build \
  mtgo-osx-cross ./bazelw --output_user_root=/build/bazel --host_jvm_args=-Xmx512m build \
  //third_party/wine:archive_arm64 //third_party/wine:archive_x86_64 \
  --jobs=1 --define=native_jobs=2 --symlink_prefix=/build/links/ --lockfile_mode=off
mkdir -p dist/linux
docker cp mtgo-osx-runtime-build:/build/links/bin/third_party/wine/wine-arm64.tar.gz dist/linux/
docker cp mtgo-osx-runtime-build:/build/links/bin/third_party/wine/wine-x86_64.tar.gz dist/linux/
docker rm mtgo-osx-runtime-build
```

Each archive includes Wine, libraries compiled for the same architecture, and license notices. To package these builds on macOS, set `MTGO_NATIVE_ARTIFACTS` to an absolute directory containing both archives:

```sh
MTGO_NATIVE_ARTIFACTS="$PWD/dist/linux" ./bazelw build //:MTGO //:dmg //:runtime_arm64 //:runtime_x86_64
MTGO_NATIVE_ARTIFACTS="$PWD/dist/linux" ./bazelw test //tests:mtgo_startup
```

Bazel imports the archives instead of scheduling Wine or dependency compilation. Packaging verifies each Mach-O architecture and signs the native binaries before creating the release archives and app. Without `MTGO_NATIVE_ARTIFACTS`, local builds continue to compile Wine from source.

## Launch Flow

On first launch, MTGO-OSX downloads a Wine runtime using a URL and SHA-256 hash recorded in `RuntimePackages.json`. Before installation, validation also checks binary architectures, Dock protocol compatibility and the helper app signature. Later launches reuse that installation without contacting GitHub. Runtime versions are independent of MTGO client updates.

Windows files, registry data and installed applications are stored in a separate directory called a Wine prefix. Setup prepares this prefix with architecture-matched .NET Framework files downloaded from Microsoft, then uses the Native Image Generator (`ngen.exe`) to compile Framework assemblies before starting MTGO. This preparation is reused on later launches.

A version lookup runs against the [Videre manifest API](https://api.videreproject.com/mtgo/manifest) while runtime and prefix preparation proceed. MTGOSDK compares that version with the installed ClickOnce subscription and activates a current deployment without contacting the MTGO update provider. If an installation is missing or older, or the API is unavailable, startup follows the SDK update path. An installed deployment can still start if the provider check fails.

By default, the launcher covers installation, updates and the wait for the main game window, then transitions into MTGO. Progress and expandable activity groups show setup details; groups start collapsed so assembly output does not push later stages out of view. The version at the bottom reports MTGO's installed version when available, falling back to the latest version retrieved from Videre. It is separate from app and runtime release versions.

Setup and gameplay share one MTGO icon and Dock entry, even though the native UI and game windows run in separate processes. Wine runs as an accessory application so that entry can remain in place when the launcher gives way to the game. Clicking it restores the game window; reopening the app focuses the active session. Closing the main game window removes the Dock entry while the remaining shutdown work finishes in the background.

MTGO's original splash screen is hidden during startup. ClickOnce shortcuts stay inside the Wine prefix, with cached activation using a private Start Menu reference, so installation does not add shortcuts to the Mac desktop.

Hardware rendering is the default. Software rendering is available in Settings; foil treatments and other Shader Model 3 effects require hardware rendering. The optional OpenGL comparison app is `//:MTGO_opengl`.

MTGO-OSX installs Wine runtimes under `~/Library/Application Support/MTGO-OSX/Runtimes/<version>/<architecture>` and creates Wine prefixes under `~/Library/Application Support/MTGO-OSX/Prefixes/<architecture>`. Existing ARM64 installations under `Prefix` are retained. Verified downloads are cached in `~/Library/Caches/MTGO-OSX/Packages`.

For diagnostics, choose **MTGO → Show Session Log** or use the document button in the launcher. Logs are stored under `~/Library/Application Support/MTGO-OSX/Logs`. See [Runtime Architecture](docs/runtime.md) for validation, Framework setup and session handling.

### Settings

Open **MTGO → Settings…** to change appearance, attention behavior and runtime options. Appearance includes a custom app icon and the startup transition; Behavior controls the attention badge and progress on routine launches. Installation, updates and errors remain visible when routine progress is disabled. Transitions and badge pulses also respect Reduce Motion in System Settings.

Custom images are copied to `~/Library/Application Support/MTGO-OSX/Icons`, so moving or deleting the original image does not affect the selection. The running Dock icon changes immediately; MTGO windows use it after restarting. Reset restores the bundled MTGO icon. Finder retains the installed app icon because customization does not modify the signed bundle.

**Runtime** settings show which runtime release, processor architecture and rendering mode are in use, along with storage totals. **Advanced** provides overrides for runtime and Wine-prefix folders. When a change affects an active Wine session, Settings offers a restart option. Native preferences apply immediately.

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

- Startup progress appears within a display's usable area with its Dock entry.
- Corrupt downloads and catalogs missing a native release fail before Wine starts.
- An incompatible Wine runtime is rejected before prefix initialization.
- A fresh launch downloads the real runtime archive and installs official MTGO even when the version API is unavailable.
- A later launch reuses that runtime while its download server is unavailable.
- A current deployment relaunches without installation, migrates its desktop shortcut safely and retains one native session when opened again.
- Cached activation works without the deployment provider or desktop shortcut, and the SDK launcher exits after MTGO exits.

The lifecycle test installs MTGO once, then checks cached relaunch and offline activation using that installation. A local HTTP server supplies version responses and runtime archives; ClickOnce downloads MTGO from its official provider. Progress assertions use SDK stage names to identify the expected sequence.

Two observer processes check startup from Windows and macOS. A Win32 observer watches MTGO's main window and Common Language Runtime (CLR) and just-in-time (JIT) compiler modules for ten seconds, checking that both modules match the selected processor architecture. A macOS observer checks window placement, Dock ownership and the handoff from launcher progress to a visible MTGO main window. Fixtures in `tests/integration/fixtures.py` manage processes, temporary prefixes and logs; `run.py` starts the tests from Bazel.

`//tests:mtgo_startup` runs the ARM64 specification; `//tests:mtgo_startup_x86_64` runs it for Intel through Rosetta. The Intel target must be selected explicitly and is added to CI for tagged releases. Real-client tests require a logged-in macOS GUI session and internet access. Fixtures use disposable prefixes, retain logs under `bazel-testlogs`, and never accept MTGO's license agreement or enter account credentials. To reuse verified Framework packages, pass `--test_env=MTGO_TEST_PACKAGE_CACHE=/path/to/cache`.

`//tests:launcher_startup` checks the native launcher window. Other targets cover behavior that can be tested separately from a full MTGO installation:

| Target | Behavior |
| --- | --- |
| `//tests:dock_attention` | Runs a Win32 fixture that requests and stops attention, regains focus and closes its window. Native checks observe dock icon changes, animation and focus behavior after extracting a signed release archive. |
| `//tests:dock_attention_x86_64` | The same attention check with Intel Wine through Rosetta. |
| `//tests:settings` | Native preference panes, saved selections, icon import and reset, transition controls, and storage totals that exclude Wine links into host folders. Pane captures are retained in test outputs. |
| `//tests:preparation` | Framework component installation for both architectures, progress after successful writes, and user-data migration, reset, conflicting stores and unavailable folders. |

Attention and settings tests require a GUI session and run exclusively because they change foreground focus. Preparation tests use file fixtures without starting Wine. The real-client specification connects these checks to installation: it exercises download, extraction and NGen, starts ClickOnce with an external user-data folder, and verifies that hiding routine progress still permits setup and errors to appear.

A startup test passes when MTGO keeps a main window open with CLR and JIT modules that match the selected processor architecture. Window responsiveness, rendered pixels, animation appearance, login and gameplay require manual validation. Checks for skipped provider requests rely on SDK diagnostics. Native-image checks verify generated files and their architecture; they do not establish that MTGO loaded those files.

Run the main CI test set locally with:

```sh
./bazelw test //tests:launcher_startup //tests:settings //tests:preparation \
  //tests:mtgo_startup //tests:dock_attention
```

### CI and Incremental Builds

On pushes to `main` and pull requests, the [build workflow](.github/workflows/build.yml) prepares an Apple SDK archive on macOS, then builds Wine and its dependencies in two parallel Linux jobs: ARM64 on `ubuntu-24.04-arm` and Intel on `ubuntu-24.04`. A macOS job imports both outputs, signs and packages the runtimes, builds the universal app and DMG, and runs the tests above. Version tags add Intel lifecycle and attention tests before release staging.

Workflow timeouts allow 15 minutes for SDK preparation, 60 minutes for each Linux runtime build, and 45 minutes for macOS packaging and tests. Each Linux job runs one Bazel action at a time with four compiler jobs. After testing, CI uploads a DMG, runtime archives, catalog and checksums as `MTGO-macos`. Linux build logs are uploaded per architecture; macOS test logs are in `mtgo-startup-logs`.

CI caches build tools, downloaded packages and compiled outputs separately:

| Cache | Reused content |
| --- | --- |
| Apple SDK archive | SDK files and Darwin compiler runtime, keyed by SDK settings, compiler identity and runtime hash. |
| Linux toolchain image | BuildKit layers containing Clang, OSXCross and SDK files, scoped by host architecture. |
| Linux build cache | Dependency downloads, completed library builds and unsigned Wine archives, separated by host, target and toolchain image. |
| macOS build cache | Imported runtimes, compiled Swift and launcher binaries, signed bundles, release archives and DMG files. Keys include compiler versions, build inputs and transferred archive hashes. |
| Framework downloads | Verified Microsoft installer and activation DLLs. Wine prefixes and installed MTGO clients are created afresh for integration tests. |

GitHub Actions looks for a cache key matching current build inputs and restores a compatible earlier entry if that key is unavailable. Bazel then checks input hashes before reusing individual build outputs. Editing launcher UI code can reuse Wine, while changing a Wine patch recompiles Wine. Dependencies such as GnuTLS and FreeType remain reusable when their inputs are unchanged. Bazel caches complete build actions; compiler object files are not cached individually. Linux jobs keep Bazel installation files outside the shared cache because those directories must belong to the user running Bazel.

GitHub Actions cache entries cannot be overwritten, so failed builds save completed actions under a separate partial key. A later successful run can restore those actions and save a complete entry under the original input key. Integration tests run on every invocation with `--nocache_test_results`.

### Intel Testing

For manual Intel testing on Apple silicon, build the Intel-only launcher and use the local runtime until release assets are published:

```sh
./bazelw build //src:MTGO_intel //:runtime_x86_64
runtime_dir="$(mktemp -d)"
tar -xJf bazel-bin/src/runtime-0.1.0-macos-x86_64.tar.xz -C "$runtime_dir"
MTGO_RUNTIME_ROOT="$runtime_dir" \
MTGO_PREFIX_ROOT="$HOME/Library/Application Support/MTGO-OSX/Prefixes/x86_64" \
  bazel-bin/src/MTGO_intel.app/Contents/MacOS/MTGO
```

This test bundle permits Rosetta. The universal distribution bundle requires native execution and selects its runtime accordingly. Rosetta testing does not establish compatibility with Intel GPUs.

## Releases

A push to `main` builds and tests without creating releases. Pushing an app tag such as `v0.1.0` starts the [release workflow](.github/workflows/release.yml), which runs the shared build and ARM64 and Intel lifecycle tests before preparing one draft release. It includes a DMG, both runtime archives and `RuntimePackages.json`. GitHub generates release notes for review and editing before publication.

App tags must match `CFBundleShortVersionString` in `src/Info.plist`, which also determines runtime download URLs. Runtime archives remain versioned by `RUNTIME_VERSION` in `src/BUILD.bazel`; bump this when changing runtime contents. MTGO-OSX can reuse an installed runtime across app releases when its version and checksum match.

Publishing a draft makes the DMG and runtime assets available together. Rerunning the workflow can refresh draft assets while preserving edited notes; published releases cannot be replaced. GitHub provides SHA-256 digests for uploaded assets. An internal `SHA256SUMS` file verifies files transferred between CI jobs and stays in CI artifacts.

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
