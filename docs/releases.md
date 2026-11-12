# Releases

## Publish a Release

1. Push your changes to `main` and wait for [build CI](../.github/workflows/build.yml) to pass.
2. From that same commit, create and push a `v<major>.<minor>.<patch>` tag:

   ```sh
   git tag v0.1.1
   git push origin v0.1.1
   ```

3. Review and publish the generated draft on GitHub.

Draft notes include a [download table](../.github/release-notes.md) and GitHub's generated changelog. Rerunning Release refreshes draft assets and preserves edited notes.

## Versioning

| Value | Source |
| --- | --- |
| App version (`CFBundleShortVersionString`) | Release tag without `v`. |
| Build number (`CFBundleVersion`) | Release workflow run number. |
| Runtime version | `RUNTIME_VERSION` in [src/BUILD.bazel](../src/BUILD.bazel); update when runtime contents change. |
| Development version | `0.0.0`, build `0`. |

Set app versions through tags, without editing `src/Info.plist`. Changing an app version retains runtime archives and their hashes.

## Release Jobs

| Job | Host | Work |
| --- | --- | --- |
| Select build | Linux | Find a main-branch build for the tagged commit and wait for it to pass. |
| Sign and package | macOS | Verify inputs, stamp app metadata and runtime URLs, sign the app and create a DMG. |
| Prepare draft release | Linux | Verify final checksums, generate attestations and upload draft assets. |

- **Downloads:** one DMG, ARM64 and Intel runtime archives, and `RuntimePackages.json`.
- **Verification:** GitHub digests and attestations for final assets; `SHA256SUMS` for CI transfers.
- **Signing:** ad-hoc. Developer ID signing and notarization are not configured.

## Retry a Failed Release

| Condition | Action |
| --- | --- |
| Build still running | Wait; Release follows its result. |
| No main-branch build | Push the commit to `main`, then rerun Release. |
| Build failed, or artifacts are missing or expired | Rerun the main-push Build run for that commit, then rerun Release. |
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
