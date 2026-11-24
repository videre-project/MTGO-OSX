# Releases

## Publish a Release

1. Add a version section at the top of [CHANGELOG.md](CHANGELOG.md) using `## [version] - YYYY-MM-DD`.
2. On `main`, tag the release commit and push both refs together.

   ```sh
   git tag v0.2.1
   git push --atomic origin main v0.2.1
   ```

Release waits for a successful [Build](../.github/workflows/build.yml) on `main` for the tagged commit, then publishes on GitHub once all assets have uploaded.

Release notes use a [download and installation template](../.github/release-notes.md) and the changelog entry for the tag. If an upload fails, rerun Release to finish publishing the draft.

## MTGO Maintenance

Set the repository Actions variable `SKIP_MTGO_STARTUP_TESTS` to `true` before queuing Build to skip the live installation and startup scenario on ARM64 and Intel. Build still runs launcher, runtime validation, Dock and release packaging tests. Clear the variable when service returns.

## Versioning

| Value | Source |
| --- | --- |
| App version (`CFBundleShortVersionString`) | Release tag without `v`. |
| Build number (`CFBundleVersion`) | Release workflow run number. |
| Runtime version | `RUNTIME_VERSION` in [src/BUILD.bazel](../src/BUILD.bazel); update when runtime contents change. |
| Development version | `0.0.0`, build `0`. |
| Release title | `MTGO-OSX v<major>.<minor>.<patch>`. |
| DMG volume | `MTGO-OSX`, containing `MTGO.app`. |

Set app versions through tags, without editing `src/Info.plist`. Changing an app version retains runtime archives and their hashes.

## Release Jobs

| Job | Host | Work |
| --- | --- | --- |
| Select build | Linux | Find a main-branch build for the tagged commit and wait for it to pass. |
| Sign and package | macOS | Verify inputs, stamp app metadata and runtime URLs, sign the app and create a DMG. |
| Publish GitHub release | Linux | Verify checksums, attest and upload assets, then publish. |

- **Downloads:** `MTGO-OSX-<version>.dmg`, ARM64 and Intel runtime archives, and `RuntimePackages.json`.
- **Verification:** GitHub digests and attestations for final assets; `SHA256SUMS` for CI transfers.
- **Signing:** ad-hoc. Developer ID signing and notarization are not configured.

## Retry a Failed Release

| Condition | Action |
| --- | --- |
| Build still running | Wait; Release follows its result. |
| No main-branch build | Push the tagged commit to `main` or run Build manually on `main` at that commit. Rerun Release. |
| Build failed, or artifacts are missing or expired | Rerun Build for that commit, then rerun Release. |
| Checksum mismatch | Regenerate inputs through Build, then rerun Release. |
| Release already published | Use a new version tag; Release does not overwrite published assets. |

## Package Locally

Run from the repository root. Choose output directories that do not already exist.

```sh
python3 -m unittest discover -s tests -p release_test.py -v
./bazelw build //:MTGO //:dmg_inputs //:runtime_arm64 //:runtime_x86_64
python3 tools/release.py stage --output dist/build
python3 tools/release.py package --directory dist/build --tag v0.1.1 --build-number 1 --output dist/release
python3 tools/release.py verify --directory dist/release --tag v0.1.1
```
