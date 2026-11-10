# Runtime Architecture

MTGO runs as a Windows process under Wine, with a native SwiftUI and AppKit launcher for installation and macOS integration. Wine creates game windows through its Mac driver while the launcher provides macOS menus, settings and a shared Dock entry. These remain available after the startup window closes.

Wine, .NET Framework 4.8.1 and MTGO run as ARM64 processes on Apple silicon and x86_64 processes on Intel Macs. Windows Presentation Foundation (WPF) renders MTGO through Direct3D 9/9Ex; with hardware rendering enabled, DXVK translates those calls to Vulkan and MoltenVK translates Vulkan to Metal. Game windows use Wine's Mac driver directly, without XQuartz or VNC.

## Runtime Installation

MTGO-OSX is distributed as a universal app with a `RuntimePackages.json` catalog listing download URLs and SHA-256 hashes for ARM64 and x86_64 archives. Wine, DXVK, MoltenVK, 7-Zip and dependency notices are packaged in those archives, allowing one DMG to support both architectures while downloading only the matching runtime. Archive hashes are generated during the build and remain tied to a runtime release version, independently of MTGO updates. See [Releases](../README.md#releases) for publication order.

After verifying a download, installation extracts it into a staging directory on the installation volume. A `runtime.json` manifest identifies binaries inside a nested `MTGO.app` helper bundle. Validation checks the manifest schema, Dock protocol, minimum macOS version and binary architectures, followed by a strict signature check of the helper. Cancellation is checked before placing the validated directory at `~/Library/Application Support/MTGO-OSX/Runtimes/<version>/<architecture>` and registering the helper with Launch Services. Failed validation leaves earlier releases unchanged.

Later launches reuse a runtime when its `.archive.sha256` marker matches the bundled catalog and manifest and binary checks still pass. The cached-installation check does not rehash every installed file or repeat signature verification. [RuntimeInstaller.swift](../src/Runtime/RuntimeInstaller.swift) controls installation and reuse; [WineRuntime.swift](../src/Runtime/Wine/WineRuntime.swift) defines runtime validation.

## .NET Framework and the Wine Prefix

A Wine prefix contains Windows files, registry data and installed applications. It is separate from the downloaded runtime, so multiple prefixes can use the same Wine installation while retaining separate MTGO installations and settings.

[FrameworkInstaller.swift](../src/Runtime/Framework/FrameworkInstaller.swift) initializes or updates a prefix with automatic Common Language Runtime (CLR) registration in Wine disabled. Setup verifies downloads from Microsoft, extracts the architecture-specific .NET Framework components, and installs files and registry entries described by Microsoft component manifests. Native activation libraries (`mscoree.dll` and `dfshim.dll`) and COM type-library metadata complete CLR and ClickOnce registration. Microsoft and MTGO assemblies are used unchanged.

ARM64 Framework files are installed under `C:\windows\Microsoft.NET\FrameworkArm64\v4.0.30319`; Intel files use `Framework64` instead. Resource-only type libraries are also retained in `Framework64` for ARM64 COM registration. Installation is reused when the `.mtgo-framework.sha256` marker matches the pinned package, `mscoree.tlb` is present, and `clr.dll` and `clrjit.dll` match the selected architecture.

Configuration is applied on every launch so existing prefixes receive changes without reinstalling Framework files. In particular, [FrameworkConfiguration.swift](../src/Runtime/Framework/FrameworkConfiguration.swift) maps `SHA256.Create()` to `System.Security.Cryptography.SHA256Cng` in `machine.config`. MTGO can therefore use the Windows Cryptography Next Generation (CNG) provider for card-data hashing without assembly changes.

The Native Image Generator (`ngen.exe`) compiles `PresentationFramework.dll` and its dependencies before MTGO starts. An `.mtgo-native-images.sha256` marker records the attempt once per Framework package. If compilation fails, setup reports a warning and continues with just-in-time (JIT) compilation; recording the attempt prevents a failed optimization from delaying every launch. The marker records an attempt, so its presence alone does not establish that native images were generated or loaded.

ClickOnce shortcuts are written to a `Desktop` directory inside the prefix, keeping `.appref-ms` files off the Mac desktop. Cached activation uses a private Start Menu reference, so deleting a desktop shortcut does not prevent launch.

### User Data

Settings can place ClickOnce user data in a chosen Mac folder while retaining a symlink at `drive_c/users/<user>/AppData/Local/Apps/2.0/Data`. MTGO and the SDK continue using that Wine path, including ClickOnce's generated deployment and account subdirectories. This exposes existing game-history files, settings and log caches without changing their formats or combining data from different deployments.

A folder selection is captured at session startup and applied before Wine starts. It must identify an existing, writable directory outside the prefix and separate from the current store. When data needs copying, migration stages it on the destination volume before replacing the Wine path with a symlink. Directory swaps keep that path present during replacement.

An empty or absent current store can use a destination that already contains data. Otherwise, existing destination contents must match the current store, allowing a completed copy from an interrupted migration to be reused. Differing stores are rejected without merging or overwriting files. These checks and replacement operations are implemented in [WineUserData.swift](../src/Runtime/Wine/WineUserData.swift).

Reset copies the active data into a normal directory inside the prefix and removes only the symlink. The external copy remains available. A missing backing folder stops launch or reset; it is not replaced with an empty store. Existing manual mappings are retained until a location is explicitly selected or reset in Settings, including when another prefix is selected.

## ClickOnce Activation and Updates

A current deployment can skip installation while still starting through ClickOnce activation. MTGOSDK provides `Launcher.exe --progress-json --start-and-wait` for this activation and progress reporting. It remains running until the MTGO process exits.

A request to the [Videre manifest API](https://api.videreproject.com/mtgo/manifest) starts alongside runtime and prefix preparation, with a three-second timeout. The returned version is passed to the SDK through `--expected-version` and compared with the installed ClickOnce subscription. A matching or newer subscription starts from its cached activation context without contacting the MTGO provider; a missing, older or unreadable subscription follows the installation or update path.

If the version API is unavailable, the SDK performs its usual ClickOnce update check. An installed deployment can still start if the provider check fails. These decisions remain in the SDK, allowing the native UI to report progress for installation, updates and cached startup through the same interface.

Only recognized JSON progress records from stdout update the native UI; process output is retained in a session log alongside Wine diagnostics. [LauncherSession.swift](../src/Launcher/LauncherSession.swift) combines SDK reports with runtime and Framework installer events into an activity history. Groups start collapsed and retain user disclosure choices, while starting MTGO appears only in the main status. Download estimates use bytes received and elapsed time for the current transfer. The ClickOnce launcher is extracted unchanged from the pinned MTGOSDK NuGet package; see [package extraction](../third_party/mtgosdk) for build details.

The same progress bar covers Wine, .NET Framework and MTGO setup. Downloads show received bytes, percentages and transfer estimates when a total is available. Wine installation advances through extraction, verification and registration; Framework installation counts completed component manifests. The bar resets between phases. Framework extraction, activation and NGen use an indeterminate bar, with the current assembly shown during optimization.

Runtime, prefix, user-data folder, rendering and Wine icon settings are captured when a session starts. Changing them during a session shows a restart option so game processes can continue with a consistent configuration until restart. Attention, startup-progress and transition preferences apply to the native UI immediately, as does the Dock image for a selected icon.

## macOS Integration

During gameplay, the native launcher remains a regular AppKit application and Wine runs as an accessory application. Menus and the Dock entry therefore remain available after the launcher window disappears. Native window commands are forwarded to the Wine process displaying the game.

Wine runs from an executable inside a nested `MTGO.app` bundle, supplying the MTGO name and icon for windows and minimized thumbnails. This helper is part of the downloaded runtime; the universal app remains the user-facing entry point.

### Window Commands and Activation

The launcher and Mac driver communicate through distributed notifications scoped by `WINE_DOCK_OWNER_PID`, which contains a native launcher process ID (PID). Separate launcher processes can therefore receive reports for their respective sessions. Before registering a game process, the launcher checks its executable against the canonical `wineLoader` path in `runtime.json`. Wine's `wine` bootstrap shim is a separate executable.

An activation notification restores a minimized game window even when Wine is already active. File → Close Window and Window → Minimize or Zoom forward a fixed set of actions when the game has focus; native launcher and Settings windows use AppKit actions. Wine checks the launcher PID before applying a forwarded request to its key or main window.

Clicking MTGO after using another app also requires a menu-bar change. The native launcher activates first, then returns focus to Wine after AppKit confirms activation. The current menu-bar application is checked before repeating this exchange to avoid an activation loop, including when a native Settings window remains open.

The runtime manifest must declare schema version 2 and `dockProtocolVersion: 5`. These are checked before starting Wine because the driver must support the window notifications, attention reports and commands used by the launcher.

### Taskbar Attention

MTGO calls `FlashWindowEx` when a Windows taskbar button should flash. Wine's Mac driver forwards taskbar requests through the Dock bridge, and an orange dot appears on MTGO's existing Dock icon while another app is active. The dot pulses twice before remaining steady; Reduce Motion skips those pulses. Returning to MTGO, an explicit stop request or session shutdown clears it. Caption-only requests do not change the indicator.

This reports application attention rather than a count of unread messages. It does not read toast contents or activate MTGO. Dock drawing returns to AppKit after the indicator clears, and no redraw timer runs while the dot is steady.

Settings can disable the indicator or keep it steady from the first request. Changing modes updates pending attention without another request from MTGO. A custom icon also replaces the image beneath an active badge without clearing that request.

### Custom Icons

Image import fits the selected image into a 1024 × 1024 PNG while preserving aspect ratio and transparency. Copies are stored under `~/Library/Application Support/MTGO-OSX/Icons` with content-based names, allowing an active Wine session to keep an earlier selection. Saved preferences refer to these copies, so the original image can be moved or deleted. Missing or unreadable copies fall back to the bundled icon when settings are loaded.

The native Dock entry updates immediately through AppKit. Wine reads its icon path from the startup registry on the next session, including for minimized thumbnails. Neither the installed app nor a downloaded runtime bundle is modified; Finder continues to use the packaged icon.

### Startup Transition

By default, the launcher remains visible until both the SDK's `Started` report and the Mac driver's main-window bounds are available. These reports may arrive in either order. During this interval, `WINE_DOCK_STARTUP_TRANSITION=1` keeps the game window transparent, and MTGO's original `KickerWindow` splash screen is suppressed.

The launcher background then expands to the game window's bounds over 200 ms while its controls fade at their original size. MTGO fades in at its final dimensions during the same interval. The activation notification includes `transitionDuration` for this initial display. Restoring a minimized window uses ordinary activation. Reduce Motion or disabling transitions in Settings reveals MTGO immediately.

Routine progress can be hidden in Settings while retaining the Dock entry during startup. Runtime downloads, Framework preparation, MTGO installation and errors still display the launcher. That choice is recorded for the current launch once setup begins, preventing the window from disappearing between preparation stages.

### Shutdown and Reopening

MTGO can continue running briefly after its main window closes. The Mac driver reports main-window destruction separately from process exit so the native Dock entry can disappear while shutdown finishes. Minimizing a window or recreating its Cocoa surface does not end the session.

The launcher keeps a kernel record lock on `.mtgo-session.lock` until cleanup completes. Another invocation uses `F_GETLK` to identify the process holding that lock, sends it a standard reopen event and exits. While shutdown is in progress, a reopen request clears the previous activity and displays the launcher, then waits for cleanup before starting the next session. Cancelling the request leaves shutdown running.

Locks apply per prefix, allowing separate prefixes to run independently. The lock is released if the native launcher exits; a process-exit monitor also closes the Windows UI if the launcher is force-quit. When `WINE_DOCK_OWNER_PID` is unset, Wine uses its standard application behavior.

## Runtime Builds

Wine is built against GnuTLS, FreeType and MoltenVK. DXVK D3D9 is downloaded from MetalSharp's published `v3.1.1-macos.3` packages, with ARM64X code for the ARM64 runtime and an Intel DLL for x86_64. Package hashes, source revision and license notices are retained. Updating DXVK repackages a runtime without rebuilding Wine; the default Metal app and an optional `MTGO_opengl` comparison app continue to share one Wine build.

[`third_party/sources.lock.json`](../third_party/sources.lock.json) records URLs, revisions and SHA-256 hashes for source archives and published binaries. Each dependency's `BUILD.bazel` declares build options or selected binary files. Configure and CMake build the remaining upstream sources, with scheduling and caching managed through Bazel.

`native_library` generates ARM64 and x86_64 variants from shared recipes. macOS builds currently use Rosetta for Intel recipes. Linux builds use native host executables and an OSXCross toolchain targeting macOS; Wine's resource and font tools are built for Linux with host FreeType and NLS locale data before building the macOS binaries. GnuTLS and FreeType use target-specific Darwin binutils and pkg-config directories to avoid linking against Linux libraries.

The Linux toolchain fingerprint includes Clang, host build-utility and FreeType versions, OSXCross configuration, SDK settings and the Darwin compiler-runtime hash. Native executable headers are checked against the requested architecture after library paths are normalized. Linux outputs remain unsigned until macOS packaging. `native_archive` produces transferable Wine archives as cached Bazel outputs, retaining library and license files. With `MTGO_NATIVE_ARTIFACTS` set, macOS builds import those archives and check and sign each native executable before bundling. See [Linux Runtime Builds](../README.md#linux-runtime-builds) for local commands and [CI and Incremental Builds](../README.md#ci-and-incremental-builds) for job and cache behavior.

### Packaging

Packaging rewrites native library paths and copies files referenced by Bazel's absolute input links so the runtime can be moved out of the build directory. Wine's internal relative symlinks are retained.

Packaging preserves the modification time of `wine.inf`, which Wine uses to decide whether a prefix needs updating. Rebuilding only the launcher can therefore reuse a prefix without triggering an update from a changed timestamp.

Wine modules in Portable Executable (PE) format use 16 KB file alignment and 64 KB section alignment on ARM64. Common Object File Format (COFF) symbol tables are removed from packaged modules to reduce size, while those symbols remain available in Wine build outputs for diagnostics.

Signed runtime bundles are archived before Bazel caches directory outputs, preserving relative links and modification times across cache restoration. Release packaging copies these archives unchanged to versioned filenames and records SHA-256 checksums in catalog entries.

### ARM64 Compatibility

Windows ARM64 and macOS ARM64 differ in memory layout, register use and page behavior. Patches to Wine adapt AnyCPU and ARM64X loading, Windows stack unwinding, the macOS executable layout and `x18` register handling.

The Windows shared-data page (`KUSER_SHARED_DATA`) and thread environment blocks (TEBs) are allocated at high addresses to avoid Darwin's reserved range. Windows code can still access shared data at its fixed address, so Wine's ARM64 signal handler emulates supported integer loads from that page. Other instructions follow normal exception handling. Additional patches handle CLR stores, macOS write-or-execute (W^X) permission transitions and instruction-cache synchronization.

These changes cover specific access patterns. A 16 KB host page does not reproduce every Windows 4 KB page behavior, so changes to Wine, .NET Framework or MTGO still require integration testing. Patch order is declared in [`third_party/wine/BUILD.bazel`](../third_party/wine/BUILD.bazel). ARM64 compatibility patches are excluded from Intel builds; window, Dock, graphics-context and message-queue fixes apply to both architectures.

### macOS Compatibility

Compilation targets macOS 13 for the launcher and native dependencies. A runtime can require a newer release through `minimumMacOSVersion`, checked before startup; current manifests specify `13.0`. This build setting does not establish the oldest working OS, which still requires running MTGO on that release. MoltenVK uses public Metal APIs, with newer Metal and MetalFX declarations compiled according to SDK availability.

The distribution app sets `LSRequiresNativeExecution` and selects the runtime matching its native architecture. An Intel-only development bundle, `MTGO_intel`, permits Rosetta so the same launcher and x86_64 Windows code can be tested on Apple silicon. Compatibility with physical Intel Macs and Intel GPUs remains a separate validation requirement.

## References

- [Wine's ARM64 macOS announcement](https://list.winehq.org/hyperkitty/list/wine-devel%40list.winehq.org/thread/CKG5CEN2BE5VRXZ7O7NX4YUSBH3247WH/)
- [Arm's A64 instruction reference](https://developer.arm.com/documentation/ddi0602/latest/)
- [ClickOnce unmanaged activation API](https://learn.microsoft.com/visualstudio/deployment/clickonce-unmanaged-api-reference)
