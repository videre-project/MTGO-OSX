# Changelog

## [0.3.7] - 2026-11-24

### Fixed

- Allow MTGO to display the portion of a card art crop that falls within the bitmap when the requested crop extends past an edge.

## [0.3.6] - 2026-11-24

### Fixed

- Fix missing hyphens in MTGO when Calibri is unavailable.

### Changed

- Publish GitHub releases automatically once all release assets have been uploaded.

## [0.3.5] - 2026-11-23

### Fixed

- Fix a Wine WMI error that prevented MTGO from displaying its error dialog after a fatal exception. ([#6](https://github.com/videre-project/MTGO-OSX/issues/6))

## [0.3.4] - 2026-11-19

### Fixed

- Fix a crash when clicking or tabbing into a login field on Macs set to English (Switzerland) or another locale without a fixed Windows locale ID. Wine supplies a valid keyboard language ID while preserving regional date and number formats. ([#4](https://github.com/videre-project/MTGO-OSX/issues/4))

## [0.3.3] - 2026-11-19

### Fixed

- Reduce GPU memory use in Collection by sizing temporary Metal buffers for each triangle fan.

## [0.3.2] - 2026-11-18

### Fixed

- Fix mouse clicks on the macOS menu bar while MTGO has focus. Keep MTGO minimized when using the menu bar and restore it when clicking its Dock icon.

## [0.3.1] - 2026-11-18

### Fixed

- Restore keyboard focus to modal dialogs.
- Restore missing WPF checkmarks, including the Remember this device checkbox on the login screen.
- Fall back to WineD3D on GPUs that lack features required by DXVK. ([#3](https://github.com/videre-project/MTGO-OSX/issues/3))

### Changed

- Wait for the matching build when a release tag and its commit are pushed together. Allow CI to skip live MTGO startup tests during maintenance.
- Pin the .NET 10 SDK for builds.

## [0.2.0] - 2026-11-17

### Fixed

- Map Command shortcuts such as Copy and Paste to their Windows Control equivalents.
- Reset the ClickOnce timeout whenever an installation or update makes progress. [MTGOSDK 1.9.1](https://www.nuget.org/packages/MTGOSDK/1.9.1.20261117)

## [0.1.5] - 2026-11-16

### Fixed

- Restore artwork and installation instructions in the DMG’s Finder window.

## [0.1.4] - 2026-11-16

### Fixed

- Fix partial-page decommit and single-register stores in ARM64 Wine.

### Changed

- Use MTGO-OSX for DMG filenames and GitHub release titles.
- Build Wine with shared ARM64 patches from mtgo-docker.

## [0.1.3] - 2026-11-12

### Changed

- Organize documentation for settings, development, runtime compatibility and releases.

## [0.1.2] - 2026-11-12

### Fixed

- Allow setup to replace read-only graphics DLLs in a Wine prefix.

### Changed

- Add installation steps to the DMG and direct download links to GitHub release notes.
- Reuse build artifacts for releases and set the app version from the release tag during packaging.

## [0.1.0] - 2026-11-11

### Added

- Install and run MTGO on Intel and Apple silicon Macs with one universal app. Setup downloads Wine for the Mac’s architecture.
- Manage MTGO installation and updates through ClickOnce, with launcher progress, settings and session logs.
- Integrate MTGO windows with the macOS Dock and menu bar.
