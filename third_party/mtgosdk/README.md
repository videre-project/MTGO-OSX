# MTGOSDK Launcher

## Build the Launcher

Requires macOS and the .NET 10 SDK. Run from the repository root:

```sh
./bazelw build //third_party/mtgosdk:launcher
```

Output: `bazel-bin/third_party/mtgosdk/launcher/`.

| File | Extracted from |
| --- | --- |
| `Launcher.exe` | Embedded resources in `MTGOSDK.dll`. |
| `System.Deployment.dll` | Embedded resources in `Launcher.exe`. |

Both files are packaged unchanged with license notices under `Contents/Resources/Launcher`. The installed app runs them under .NET Framework in Wine.

## Update the Package

Update the NuGet URL and SHA-256 in [MODULE.bazel](../../MODULE.bazel). Current pin: [MTGOSDK 1.9.0.20261109](https://www.nuget.org/packages/MTGOSDK/1.9.0.20261109).

| Change | File |
| --- | --- |
| NuGet file mapping | [NuGet.BUILD.bazel](NuGet.BUILD.bazel). |
| Extraction and output packaging | [launcher.bzl](launcher.bzl). |
| Embedded assembly selection | [ExtractLauncher.cs](ExtractLauncher.cs). |

Extraction reads assembly metadata directly, without loading Windows assemblies on macOS. ClickOnce activation, update checks and progress reporting use the [published MTGOSDK implementation](https://github.com/videre-project/MTGOSDK/tree/v1.9.0/MTGOSDK/lib/Launcher).
