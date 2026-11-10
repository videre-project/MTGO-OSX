"""Discover the .NET SDK used to extract the published ClickOnce launcher."""

def _dotnet_impl(ctx):
    dotnet = ctx.which("dotnet")
    if not dotnet:
        fail("Building MTGO requires the .NET 10 SDK on the build host.")
    version = ctx.execute([dotnet, "--version"])
    if version.return_code or not version.stdout.strip().startswith("10."):
        fail("Building MTGO requires the .NET 10 SDK: " + version.stdout + version.stderr)
    ctx.watch(dotnet)
    ctx.file("toolchain.bzl", "DOTNET = %r\n" % str(dotnet))
    ctx.file("fingerprint.txt", version.stdout)
    ctx.file("BUILD.bazel", 'exports_files(["fingerprint.txt", "toolchain.bzl"])\n')

dotnet_sdk = repository_rule(
    implementation = _dotnet_impl,
    local = True,
    configure = True,
    environ = ["PATH", "DOTNET_ROOT"],
)
