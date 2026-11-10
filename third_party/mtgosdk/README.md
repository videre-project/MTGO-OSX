# MTGOSDK Launcher

The [MTGOSDK NuGet release `1.9.0.20261109`](https://www.nuget.org/packages/MTGOSDK/1.9.0.20261109) is pinned by URL and SHA-256 in [`MODULE.bazel`](../../MODULE.bazel). Building `//third_party/mtgosdk:launcher` extracts `Launcher.exe` from `MTGOSDK.dll` and `System.Deployment.dll` from that launcher. Both are copied unchanged into the app alongside license notices, so activation, update checks and progress reporting continue to use the published [MTGOSDK implementation](https://github.com/videre-project/MTGOSDK/tree/v1.9.0/MTGOSDK/lib/Launcher).

[ExtractLauncher.cs](ExtractLauncher.cs) reads assembly metadata directly without loading the Windows-only MTGOSDK assembly or its embedded launcher on macOS. Extraction requires the .NET 10 SDK on the build host; the installed app instead runs the extracted launcher under .NET Framework in Wine.
