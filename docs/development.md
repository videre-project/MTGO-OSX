# Development

## Build and Run

Requirements:

- Apple silicon Mac with Xcode or Command Line Tools.
- .NET 10 SDK.
- Rosetta for Intel runtime builds, or use [Linux cross-compilation](#linux-runtime-builds).

Run from the repository root:

```sh
./bazelw build //:MTGO //:runtime_arm64
runtime_dir="$(mktemp -d)"
tar -xJf bazel-bin/src/runtime-0.1.0-macos-arm64.tar.xz -C "$runtime_dir"
MTGO_RUNTIME_ROOT="$runtime_dir" ./bazelw run //:MTGO
./bazelw test //tests:mtgo_startup
```

Set `MTGO_RUNTIME_ROOT` to an extracted archive when running a development build. This preserves Wine's relative symlinks and supplies a runtime before release downloads are published.

| Target | Output |
| --- | --- |
| `//:MTGO` | `bazel-bin/src/MTGO.app` |
| `//:runtime_arm64` | `bazel-bin/src/runtime-0.1.0-macos-arm64.tar.xz` |
| `//:runtime_x86_64` | `bazel-bin/src/runtime-0.1.0-macos-x86_64.tar.xz` |
| `//:dmg` | `bazel-bin/dmg.dmg` for development. |

See [macOS Compatibility](runtime.md#macos-compatibility) for OS requirements and [Releases](releases.md) for version stamping and distribution packaging.

## Project Layout

| Directory | Contents |
| --- | --- |
| `src/Launcher/` | UI, settings, activity and launch orchestration. |
| `src/Runtime/` | Wine, Framework installation, downloads and binary validation. |
| `src/Dock/` | Native window commands, activation and attention. |
| `src/Resources/` | Icons, fonts and artwork. |
| `third_party/` | Dependency pins, build recipes and patches. |
| `tests/` | Integration fixtures and behavior specifications. |
| `tools/` | Bazel rules, packaging and asset generation. |
| `docs/` | Usage, development, runtime and release guides. |

### Where to Make Changes

| Change | Files |
| --- | --- |
| Launcher layout, spacing and buttons | [LauncherView.swift](../src/Launcher/UI/LauncherView.swift) |
| Fonts, colors and background artwork | [LauncherTheme.swift](../src/Launcher/UI/LauncherTheme.swift), [LauncherBackground.swift](../src/Launcher/UI/LauncherBackground.swift) |
| Window placement and transition into MTGO | [LauncherWindowController.swift](../src/Launcher/LauncherWindowController.swift) |
| Settings values and panel | [Launcher/Settings](../src/Launcher/Settings) |
| Activity display, disclosure and elapsed times | [Launcher/Activity](../src/Launcher/Activity) |
| Launch, cancellation and restart behavior | [LauncherSession.swift](../src/Launcher/LauncherSession.swift) |
| Preparation statuses and activity messages | [LauncherSession.swift](../src/Launcher/LauncherSession.swift): `reportPreparation`, `receiveProgress` |
| Progress bar, counts and download estimates | [StartupProgress.swift](../src/Launcher/StartupProgress.swift), [StartupProgressBar.swift](../src/Launcher/UI/StartupProgressBar.swift), [LauncherSession.swift](../src/Launcher/LauncherSession.swift) |
| Status wording and SDK progress records | [LauncherState.swift](../src/Launcher/LauncherState.swift), [LaunchProgress.swift](../src/Launcher/LaunchProgress.swift) |
| Videre version check | [MTGOManifest.swift](../src/Launcher/MTGOManifest.swift) |
| ClickOnce installation, updates and cached activation | [MTGOSDK](https://github.com/videre-project/MTGOSDK/tree/v1.9.0/MTGOSDK/lib/Launcher); [package extraction](../third_party/mtgosdk) |
| Runtime release selection and download | [RuntimePackage.swift](../src/Runtime/RuntimePackage.swift), [RuntimeInstaller.swift](../src/Runtime/RuntimeInstaller.swift) |
| Wine prefix, rendering configuration and runtime validation | [Runtime/Wine](../src/Runtime/Wine) |
| User-data folder and migration | [WineUserData.swift](../src/Runtime/Wine/WineUserData.swift) |
| .NET Framework installation and optimization | [Runtime/Framework](../src/Runtime/Framework) |
| Native menus and application lifecycle | [AppDelegate.swift](../src/AppDelegate.swift) |
| Dock activation, window notifications and attention | [DockController.swift](../src/Dock/DockController.swift), [DockAttentionView.swift](../src/Dock/DockAttentionView.swift) |
| Wine's Mac driver and compatibility fixes | [third_party/wine](../third_party/wine) |
| D3D9 and Metal translation | [third_party/dxvk](../third_party/dxvk), [third_party/moltenvk](../third_party/moltenvk) |
| App contents, signatures and runtime packaging | [macos.bzl](../tools/macos.bzl), [sign_runtime.py](../tools/sign_runtime.py) |
| Linux build jobs and incremental caches | [build.yml](../.github/workflows/build.yml), [Dockerfile](../tools/linux/Dockerfile) |
| Imported Wine archives | [native_artifacts.bzl](../tools/native_artifacts.bzl), [native.bzl](../third_party/native.bzl) |
| DMG artwork and Finder layout | [DMG-Background.png](../src/Resources/DMG-Background.png), [dmg.swift](../tools/dmg.swift), [dmg.py](../tools/dmg.py) |
| Dependency source URLs and hashes | [sources.lock.json](../third_party/sources.lock.json) |
| SDK package version and extraction | [MODULE.bazel](../MODULE.bazel), [MTGOSDK Launcher](../third_party/mtgosdk) |
| Final version stamping, signing and release packaging | [release.py](../tools/release.py), [release.yml](../.github/workflows/release.yml) |
| Prefix session locking and reopening | [SessionLock.swift](../src/Launcher/SessionLock.swift) |
| Process execution and logging | [NativeProcess.swift](../src/Runtime/NativeProcess.swift) |
| Binary architecture checks | [BinaryArchitecture.swift](../src/Runtime/BinaryArchitecture.swift), [RuntimeArchitecture.swift](../src/Runtime/RuntimeArchitecture.swift) |
| Verified downloads | [VerifiedDownload.swift](../src/Runtime/VerifiedDownload.swift) |

Graphics comparisons: [Metal and OpenGL targets](../third_party/wine#compare-graphics-backends).

## Linux Runtime Builds

Requirements: Docker and local copies of a macOS SDK and Darwin compiler runtime from Apple developer tools. Run the phases below sequentially; limits target a Docker VM with 4 GB RAM.

### Prepare the Toolchain

Build the image and stop BuildKit before compiling Wine:

```sh
docker buildx create --name mtgo-osx-cross --driver docker-container \
  --driver-opt memory=2g --driver-opt cpu-period=100000 --driver-opt cpu-quota=200000
docker buildx build --builder mtgo-osx-cross --load -t mtgo-osx-cross \
  --build-context macos_sdk="$(xcrun --sdk macosx --show-sdk-path)" \
  --build-context compiler_rt="$(xcrun clang -print-resource-dir)/lib/darwin" \
  tools/linux
docker buildx stop mtgo-osx-cross
```

### Compile and Export Runtimes

Use a read-only repository mount and a named volume for build outputs. These limits permit one Bazel action and two compiler jobs:

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

### Package on macOS

Set `MTGO_NATIVE_ARTIFACTS` to an absolute directory containing both exported archives:

```sh
MTGO_NATIVE_ARTIFACTS="$PWD/dist/linux" ./bazelw build //:MTGO //:dmg //:runtime_arm64 //:runtime_x86_64
MTGO_NATIVE_ARTIFACTS="$PWD/dist/linux" ./bazelw test //tests:mtgo_startup
```

Imported archives include Wine, architecture-matched libraries and license notices. Packaging validates native headers and signs binaries. Omit `MTGO_NATIVE_ARTIFACTS` to compile Wine locally.

Toolchain definition: [Dockerfile](../tools/linux/Dockerfile). Intel GMP assembly uses relocations unsupported by LLVM's Mach-O linker; OSXCross supplies ld64.

## Development Settings

Set these environment variables before launching a development build. Saved preferences and the bundled catalog remain unchanged:

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

`MTGO_RUNTIME_ROOT` takes precedence over automatic runtime selection. A custom `MTGO_RUNTIME_CATALOG` bypasses saved runtime-folder selections and bundled comparison runtimes, allowing a fixture catalog to exercise downloading. Runtime catalogs accept HTTPS release URLs and loopback HTTP for fixtures; manifests use the format in [runtime.json](../src/Runtime/Wine/runtime.json).

### Preview the Launcher

Show the native UI without starting Wine or installing MTGO:

```sh
bazel-bin/src/MTGO.app/Contents/MacOS/MTGO --preview
```

## Integration Testing

Requirements: a logged-in macOS GUI session and internet access. Intel targets require Rosetta on Apple silicon. Run the CI test set from the repository root:

```sh
./bazelw test //tests:launcher_startup //tests:settings //tests:preparation \
  //tests:mtgo_startup //tests:dock_attention \
  //tests:mtgo_startup_x86_64 //tests:dock_attention_x86_64
```

| Target | Coverage |
| --- | --- |
| `//tests:mtgo_startup` | ARM64 runtime download, installation, activation, cached relaunch and offline reuse. |
| `//tests:mtgo_startup_x86_64` | The same specification for Intel through Rosetta. |
| `//tests:launcher_startup` | Native launcher window placement and visibility. |
| `//tests:dock_attention` | Win32 attention requests, stop requests, focus changes and native Dock drawing. |
| `//tests:dock_attention_x86_64` | Intel attention behavior through Rosetta. |
| `//tests:settings` | Preference panes, icon import/reset, transitions and storage totals excluding links into host folders. |
| `//tests:preparation` | Framework components, progress, graphics DLL replacement and user-data migration/reset/conflicts. |

Attention and settings targets run exclusively because they change desktop focus. Preparation uses file fixtures without Wine. Set `--test_env=MTGO_TEST_PACKAGE_CACHE=/path/to/cache` to reuse verified Framework packages.

### Startup Specification

Source: [startup_test.py](../tests/integration/startup_test.py).

- Reject corrupt downloads, incomplete catalogs and incompatible runtimes before Wine starts.
- Install official MTGO when the version API is unavailable.
- Reuse installed runtimes after their download server stops.
- Relaunch current ClickOnce deployments without installation; migrate desktop shortcuts safely.
- Start cached deployments without the provider or desktop shortcut.
- Retain one native session after reopening and end the SDK launcher after MTGO exits.
- Keep a main window open with CLR and JIT modules matching the selected architecture.

### Fixtures and Results

| Area | Implementation or output |
| --- | --- |
| Process lifecycle, temporary prefixes and logs | [fixtures.py](../tests/integration/fixtures.py). |
| Bazel entry point | [run.py](../tests/integration/run.py). |
| Native and Win32 window observers | [observers](../tests/integration/observers). |
| Retained logs and captures | `bazel-testlogs/tests/<target>/`. |

A local HTTP server supplies version responses and runtime archives; ClickOnce downloads MTGO from its official provider. The lifecycle test installs once and reuses that installation for later checks. Fixtures do not accept license terms or enter account credentials.

### Validation Limits

| Check | Evidence |
| --- | --- |
| Startup | Main window, launcher handoff, Dock state and native CLR/JIT modules. |
| Skipped provider requests | SDK diagnostics. |
| Native images | Generated files and architecture; not proof that MTGO loaded them. |
| Responsiveness, pixels, animations, login and gameplay | Manual validation required. |

## CI and Incremental Builds

**Workflow:** [build.yml](../.github/workflows/build.yml). **Triggers:** pushes to `main` and pull requests.

| Job | Runner | Work | Timeout |
| --- | --- | --- | --- |
| Prepare Apple SDK | `macos-15` | Archive SDK and compiler runtime. | 15 min |
| ARM64 runtime | `ubuntu-24.04-arm` | Cross-compile Wine and dependencies. | 60 min |
| Intel runtime | `ubuntu-24.04` | Cross-compile Wine and dependencies. | 60 min |
| Package and test | `macos-15` | Sign runtimes, assemble the app, run ARM64 and Rosetta tests, archive release inputs. | 45 min |

Each Linux job runs one Bazel action at a time with four compiler jobs.

| Artifact | Contents |
| --- | --- |
| `MTGO-macos` | App bundle archive, runtime archives, catalog, DMG resources and checksums. |
| `native-build-logs-<architecture>` | Linux build logs. |
| `mtgo-startup-logs` | macOS build and integration logs. |

### Caches

| Cache | Reused content |
| --- | --- |
| Apple SDK archive | SDK files and Darwin compiler runtime, keyed by SDK settings, compiler identity and runtime hash. |
| Linux toolchain image | BuildKit layers containing Clang, OSXCross and SDK files, scoped by host architecture. |
| Linux build cache | Dependency downloads, completed library builds and unsigned Wine archives, separated by host, target and toolchain image. |
| macOS build cache | Imported runtimes, compiled Swift and launcher binaries, signed bundles, runtime archives and DMG resources. Keys include compiler versions, build inputs and transferred archive hashes. |
| Framework downloads | Verified Microsoft installer and activation DLLs; prefixes and MTGO installations are created afresh for tests. |

Bazel checks input hashes before reusing cached actions. Launcher changes can reuse Wine; Wine patches recompile Wine while retaining unchanged dependencies. Caching applies to complete actions, rather than individual compiler object files. Bazel installation files remain outside shared caches because their directories must belong to the current user.

Failed builds save completed actions under partial cache keys. Subsequent runs can restore those entries and save a complete cache after success. Integration tests run with `--nocache_test_results`.

## Intel Testing

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
