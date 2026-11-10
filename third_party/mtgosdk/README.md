# MTGOSDK Launcher

`MODULE.bazel` pins the [MTGOSDK NuGet release `1.9.0.20261109`](https://www.nuget.org/packages/MTGOSDK/1.9.0.20261109) and its SHA-256 hash. `//third_party/mtgosdk:launcher` extracts `Launcher.exe` from `MTGOSDK.dll`, then extracts the embedded `System.Deployment.dll` dependency. Both files are copied unchanged into the app alongside license notices.

Extraction uses the metadata reader in the .NET 10 SDK, which must be installed on the build host. ClickOnce activation, update checks and progress reporting are maintained in [MTGOSDK](https://github.com/videre-project/MTGOSDK/tree/v1.9.0/MTGOSDK/lib/Launcher).
