# Settings and Data

Open **MTGO → Settings…** for appearance, behavior and runtime preferences.

## Customize Appearance

| Setting | Effect |
| --- | --- |
| Appearance → Choose Image… | Import a custom icon; the Dock updates immediately, MTGO windows after restarting. |
| Appearance → Reset | Restore the bundled MTGO icon. |
| Appearance → Animate the transition to MTGO | Enable or disable startup animation; respects Reduce Motion. |
| Behavior → Dock indicator | Choose Off, Steady badge or Pulsing badge. Pulsing stops after two cycles and the badge stays until you return to MTGO. |
| Behavior → Show progress on routine launches | Show or hide routine startup progress. Installation, updates and errors remain visible. |

Imported images are copied into app storage, so originals can be moved or deleted. Finder keeps the packaged app icon.

## Change Runtime Settings

| Setting | Use |
| --- | --- |
| Runtime → Version and Architecture | Inspect the active runtime release and processor architecture. |
| Runtime → Rendering | Select Hardware or Software. Hardware is the default; software disables foil effects. |
| Runtime → Storage | Inspect runtime, MTGO installation and download sizes. |
| Advanced → Wine runtime | Choose a custom runtime; **Use Automatic Runtime** restores automatic selection. |
| Advanced → Wine prefix | Choose a different Windows installation directory. |

Changes affecting an active Wine session offer a restart. Startup preferences take effect on subsequent launches; attention and Dock image changes apply immediately.

## Move User Data

1. Open **Settings → Runtime** and choose a folder under **User data**.
2. Select an existing, writable folder outside the Wine prefix. It must be empty or contain matching data when migrating an existing store.
3. Restart MTGO to apply the change. Use **Show in Finder** to open the selected folder.

Existing game history, settings and cached logs are copied before switching folders. A symbolic link retains ClickOnce's expected path; see [User Data](runtime.md#user-data) for migration rules.

| Situation | Action |
| --- | --- |
| Return to prefix storage | Choose **Use Default Folder** and restart. The external copy is retained. |
| Destination contains different data | Choose an empty folder or one matching the current store. |
| External folder is unavailable | Reconnect it before relaunching or resetting to default storage. |

## Open Session Logs

Choose **MTGO → Show Session Log**, or click the document button in the launcher.

## Storage Locations

| Contents | Default location |
| --- | --- |
| Wine runtimes | `~/Library/Application Support/MTGO-OSX/Runtimes/<version>/<architecture>` |
| Wine prefixes | `~/Library/Application Support/MTGO-OSX/Prefixes/<architecture>` |
| Session logs | `~/Library/Application Support/MTGO-OSX/Logs` |
| Imported icons | `~/Library/Application Support/MTGO-OSX/Icons` |
| Verified downloads | `~/Library/Caches/MTGO-OSX/Packages` |

Earlier ARM64 prefixes at `~/Library/Application Support/MTGO-OSX/Prefix` remain supported. The version displayed at the bottom of the launcher is MTGO's client version, separate from app and runtime releases.
