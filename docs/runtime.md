# Runtime Architecture

| Component | Implementation |
| --- | --- |
| Native launcher | SwiftUI and AppKit; installation, menus, settings and Dock integration. |
| Windows runtime | Wine and .NET Framework 4.8.1; ARM64 on Apple silicon, x86_64 on Intel. |
| Hardware rendering | WPF Direct3D 9/9Ex → DXVK → Vulkan → MoltenVK → Metal. |
| Game windows | Wine's Mac driver. |

For build commands, see [Development](development.md). For preferences and storage locations, see [Settings and Data](usage.md).

## Runtime Installation

Implementation: [RuntimeInstaller.swift](../src/Runtime/RuntimeInstaller.swift) and [WineRuntime.swift](../src/Runtime/Wine/WineRuntime.swift).

| Input or check | Requirement |
| --- | --- |
| `RuntimePackages.json` | Catalog schema 1; download URL and SHA-256 for each packaged architecture. |
| Download | SHA-256 matches its catalog entry. |
| `runtime.json` | Manifest schema 2, native architecture, Dock protocol 5 and a compatible minimum macOS version. |
| Executables and libraries | Required files exist, executables have execution permission, and Mach-O/PE headers match the selected architecture. |
| Metal backend | Both DXVK and MoltenVK are present and match the native architecture. |
| Runtime helper | `MTGO.app` passes strict code-signature verification. |

Downloads are extracted and validated in a staging directory on the installation volume. Validation and cancellation checks precede replacement of an installed runtime. Successful installation also registers the helper with Launch Services.

Reuse requires a matching `.archive.sha256` marker and passing manifest and binary-header checks. Cached installations do not repeat full file hashing or signature verification. Runtime archive hashes remain unchanged when [release packaging](releases.md) assigns app-tag download URLs.

## .NET Framework and the Wine Prefix

Implementation: [FrameworkInstaller.swift](../src/Runtime/Framework/FrameworkInstaller.swift), [FrameworkComponents.swift](../src/Runtime/Framework/FrameworkComponents.swift) and [FrameworkConfiguration.swift](../src/Runtime/Framework/FrameworkConfiguration.swift).

A Wine prefix stores Windows files, registry data and installed applications separately from runtime binaries. Multiple prefixes can use one runtime installation.

| Area | Behavior |
| --- | --- |
| Installation | Verify Microsoft downloads and install files and registry entries from component manifests, with Wine's automatic CLR registration disabled. |
| Activation | Install native `mscoree.dll`, `dfshim.dll` and COM type-library metadata. |
| ARM64 Framework path | `C:\windows\Microsoft.NET\FrameworkArm64\v4.0.30319`; retain COM resource-only type libraries in `Framework64`. |
| Intel Framework path | `C:\windows\Microsoft.NET\Framework64\v4.0.30319`. |
| Repeated launches | Reapply registry and graphics settings; map `SHA256.Create()` to `SHA256Cng` through `machine.config`. |
| Native images | Run `ngen.exe` for `PresentationFramework.dll` and dependencies before MTGO starts. |
| ClickOnce shortcuts | Keep desktop and private Start Menu references inside the prefix. |

Microsoft and MTGO assemblies are used unchanged.

| Marker | Meaning |
| --- | --- |
| `.mtgo-framework.sha256` | Package installed; reuse also requires `mscoree.tlb` and architecture checks for `clr.dll` and `clrjit.dll`. |
| `.mtgo-native-images.sha256` | NGen attempted for this package. It does not prove that native images were generated or loaded. |

NGen failure reports a warning and permits JIT compilation. Recording the attempt prevents repeated optimization delays; cancellation leaves the attempt eligible for retry.

### User Data

Implementation: [WineUserData.swift](../src/Runtime/Wine/WineUserData.swift). User instructions: [Move User Data](usage.md#move-user-data).

External folders are linked at `drive_c/users/<user>/AppData/Local/Apps/2.0/Data`, retaining ClickOnce deployment and account subdirectories. Folder selections are captured at session startup and applied before Wine starts.

| Condition | Result |
| --- | --- |
| Folder selection | Existing, writable, outside the prefix and separate from the current store. |
| Current store is empty or absent | An existing destination store can be used. |
| Current store contains data | Destination must be empty or contain matching data; migration stages a copy before replacing the Wine path. |
| Stores differ | Reject the change without merging or overwriting either store. |
| External folder is missing | Stop launch or reset; do not create an empty replacement. |
| Reset to default | Copy data into a prefix directory, remove the symlink and retain the external copy. |
| Existing manual mapping | Retain it until explicitly changed or reset, including after selecting another prefix. |

## ClickOnce Activation and Updates

Implementation: [LauncherSession.swift](../src/Launcher/LauncherSession.swift). Package extraction: [MTGOSDK Launcher](../third_party/mtgosdk).

```text
Launcher.exe --progress-json --start-and-wait [--expected-version <version>]
```

Version lookup uses the [Videre manifest API](https://api.videreproject.com/mtgo/manifest), with a three-second timeout, alongside runtime and prefix preparation.

| Condition | Launch path |
| --- | --- |
| Installed subscription matches or exceeds `--expected-version` | Cached ClickOnce activation without contacting MTGO's update provider. |
| Subscription missing, older or unreadable | SDK installation/update path. |
| Manifest API unavailable | SDK's normal ClickOnce update check. |
| Provider check fails | An installed deployment can still start. |

`Launcher.exe` retains MTGO's process handle until exit. Only recognized JSON progress records from stdout update the UI; full output and Wine diagnostics remain in session logs.

### Progress and Settings

| Phase | Display |
| --- | --- |
| Downloads | Received bytes; percentage and estimated time when a total is available. |
| Wine installation | Extraction, verification and registration steps. |
| Framework installation | Completed component manifests. |
| Framework extraction, activation and NGen | Indeterminate progress; assembly name during optimization. |

Progress resets between phases. Activity groups start collapsed and retain disclosure choices; starting MTGO appears only in the main status.

Runtime, prefix, user-data folder, rendering and Wine icon selections are captured per session. Changes to those values offer a restart. Native attention and Dock image changes apply immediately; startup preferences control subsequent launches.

## macOS Integration

The native launcher remains a regular AppKit application during gameplay; Wine runs as an accessory application. This keeps menus and one Dock entry available after the progress window closes. Wine executes inside a nested `MTGO.app` helper bundle so game windows and minimized thumbnails use MTGO branding.

### Window Commands and Activation

Implementation: [DockController.swift](../src/Dock/DockController.swift) and [Wine's Mac-driver patches](../third_party/wine).

| Contract | Behavior |
| --- | --- |
| `WINE_DOCK_OWNER_PID` | Scope distributed notifications to a native launcher PID. Without it, Wine uses ordinary application behavior. |
| Game-process registration | Verify the executable against `wineLoader` in `runtime.json`; Wine's bootstrap shim is separate. |
| Activation | Restore minimized game windows even when Wine is already active. |
| Close, Minimize and Zoom | Forward a fixed command set to Wine when the game has focus; native windows use AppKit actions. |
| Menu-bar focus | Activate the native launcher, then return focus to Wine after AppKit confirms activation. Check current activation state to prevent loops. |

Wine verifies the owner PID before applying commands to a key or main window. Runtime installation requires Dock protocol 5 for these notifications and commands.

### Taskbar Attention

Implementation: [DockAttentionView.swift](../src/Dock/DockAttentionView.swift).

| Event or setting | Indicator |
| --- | --- |
| Taskbar `FlashWindowEx` request while another app is active | Orange dot; two pulses followed by a steady badge. |
| Return to MTGO, explicit stop or session shutdown | Clear the indicator and restore ordinary AppKit drawing. |
| Caption-only request | No Dock indicator. |
| Reduce Motion or steady mode | Show a steady badge without pulsing. |
| Off mode | Disable the indicator. |

Attention reports do not contain toast contents or unread counts and do not activate MTGO. No redraw timer runs while the dot is steady. Mode and custom-icon changes update a pending indicator without another request from MTGO.

### Custom Icons

Implementation: [CustomIcon.swift](../src/Launcher/Settings/CustomIcon.swift).

Imported images are fitted into a 1024 × 1024 PNG with aspect ratio and transparency preserved, then stored under content-based names in `~/Library/Application Support/MTGO-OSX/Icons`.

| Surface | Update |
| --- | --- |
| Native Dock entry | Immediate. |
| Wine windows and minimized thumbnails | Next session, through the startup registry. |
| Finder | Packaged app icon; signed bundles are not modified. |
| Missing or unreadable imported copy | Fall back to the bundled icon when loading settings. |

### Startup Transition

Implementation: [LauncherWindowController.swift](../src/Launcher/LauncherWindowController.swift).

| Event | Behavior |
| --- | --- |
| Startup | Suppress `KickerWindow`; `WINE_DOCK_STARTUP_TRANSITION=1` keeps the game transparent. |
| SDK `Started` report and main-window bounds both available | Expand the launcher background to game bounds and crossfade over 200 ms; controls fade at their original size. |
| Reduce Motion or transitions disabled | Reveal MTGO immediately once ready. |
| Restore a minimized window | Ordinary activation, without replaying startup animation. |

Either startup report may arrive first. Initial activation carries `transitionDuration`. Hiding routine progress retains the Dock entry; downloads, setup and errors still display the launcher. Once setup begins, that visibility decision remains fixed for the current launch.

### Shutdown and Reopening

Implementation: [SessionLock.swift](../src/Launcher/SessionLock.swift) and [LauncherSession.swift](../src/Launcher/LauncherSession.swift).

| Event | Behavior |
| --- | --- |
| Main window destroyed | Remove the Dock entry while process cleanup finishes. |
| Minimize or recreate a Cocoa surface | Keep the session active. |
| Open the same prefix again | Find the lock holder with `F_GETLK`, send a reopen event and exit the new invocation. |
| Reopen during shutdown | Clear previous activity, display progress and wait for cleanup before starting again. |
| Cancel that reopen | Leave shutdown running. |
| Force-quit the native launcher | Release the kernel lock; a process-exit monitor closes the Windows UI. |

`.mtgo-session.lock` remains held through cleanup. Locks apply per prefix, permitting independent sessions for separate prefixes.

## Runtime Builds

| Change | Definition |
| --- | --- |
| Sources, binary downloads and hashes | [sources.lock.json](../third_party/sources.lock.json). |
| Wine dependencies and patch order | [Wine](../third_party/wine). |
| Metal translation | [MoltenVK](../third_party/moltenvk) and [DXVK](../third_party/dxvk/BUILD.bazel). |
| Shared build recipes and archives | [native.bzl](../third_party/native.bzl). |
| Linux commands and cache behavior | [Development](development.md#linux-runtime-builds). |

Wine links against GnuTLS, FreeType and MoltenVK. DXVK uses pinned MetalSharp `v3.1.1-macos.3` binaries: ARM64X for ARM64 and an Intel DLL for x86_64. Updating DXVK repackages runtimes without recompiling Wine. Metal and OpenGL comparison apps share a Wine build.

macOS source builds use Rosetta for Intel recipes. Linux builds use native host tools and OSXCross for macOS targets, including Linux FreeType and NLS data for Wine's build tools. Target-specific Darwin binutils and pkg-config directories prevent linking against Linux libraries.

### Packaging

| Property | Rule |
| --- | --- |
| Library paths | Rewrite for relocation; copy files behind Bazel's absolute input links. |
| Wine symlinks | Retain internal relative links. |
| `wine.inf` timestamp | Preserve it so cache restoration does not trigger prefix updates. |
| ARM64 PE layout | 16 KB file alignment; 64 KB section alignment. |
| COFF symbols | Remove packaged symbol tables; retain build outputs for diagnostics. |
| Transfer archives | Create before Bazel caches directory outputs, retaining links and timestamps. |
| Imported Wine | Validate native headers and sign binaries during macOS packaging. |

Release packaging retains runtime archives and hashes while updating app metadata and download URLs. See [Releases](releases.md).

### ARM64 Compatibility

Patch definitions: [third_party/wine/BUILD.bazel](../third_party/wine/BUILD.bazel).

| Difference | Adaptation |
| --- | --- |
| AnyCPU and ARM64X images | Native ARM64 loading. |
| Windows stack unwinding | Wine unwind fixes. |
| Darwin's reserved low-address range | Allocate `KUSER_SHARED_DATA` backing storage and TEBs at high addresses. |
| Fixed-address shared-data reads | Emulate supported integer loads in Wine's ARM64 signal handler; other accesses follow normal exception handling. |
| macOS register and memory rules | Handle `x18`, CLR stores, write-or-execute transitions and instruction-cache synchronization. |

A 16 KB host page does not reproduce every Windows 4 KB page behavior. Wine, Framework and MTGO changes still need integration coverage. ARM64 compatibility patches apply only to ARM64; window, Dock, graphics-context and message-queue fixes apply to both architectures.

### macOS Compatibility

| Setting | Value |
| --- | --- |
| App and native dependency deployment target | macOS 13. |
| Current runtime minimum | `minimumMacOSVersion: "13.0"`, checked before startup. |
| Distribution execution | Native architecture through `LSRequiresNativeExecution`. |
| Intel development bundle | `MTGO_intel` permits Rosetta. |

Under Rosetta, the Intel runtime still renders through Apple silicon’s GPU drivers. Intel and AMD graphics compatibility therefore requires testing on Intel Macs.

### Virtual Machines

For hardware rendering with a paravirtualized GPU, use a **macOS Sequoia 15.1 or later guest**. Sonoma guests can crash during Metal argument-encoder creation with `-[AppleParavirtDevice newArgumentEncoderWithLayout:]: unrecognized selector`.

[MoltenVK #2373](https://github.com/KhronosGroup/MoltenVK/issues/2373#issuecomment-2465862518) reports this issue resolved in Sequoia guests, including on a Sonoma host. [Godot #101773](https://github.com/godotengine/godot/issues/101773#issuecomment-2621471919) independently confirms the difference between Sonoma and Sequoia guests.

## References

- [Wine's ARM64 macOS announcement](https://list.winehq.org/hyperkitty/list/wine-devel%40list.winehq.org/thread/CKG5CEN2BE5VRXZ7O7NX4YUSBH3247WH/)
- [Arm's A64 instruction reference](https://developer.arm.com/documentation/ddi0602/latest/)
- [ClickOnce unmanaged activation API](https://learn.microsoft.com/visualstudio/deployment/clickonce-unmanaged-api-reference)
