"""Make transferred Wine archives available to the macOS packaging targets."""

def _native_artifacts_impl(ctx):
    root = ctx.os.environ.get("MTGO_NATIVE_ARTIFACTS", "")
    files = []
    if root:
        if not root.startswith("/"):
            fail("MTGO_NATIVE_ARTIFACTS must be an absolute directory path.")
        for architecture in ["arm64", "x86_64"]:
            name = "wine-" + architecture + ".tar.gz"
            archive = ctx.path(root + "/" + name)
            if not archive.exists:
                fail("Missing transferred Wine build: " + str(archive))
            ctx.watch(archive)
            ctx.symlink(archive, name)
            files.append(name)
    ctx.file("configuration.bzl", "USE_IMPORTED_WINE = %r\n" % bool(root))
    ctx.file("BUILD.bazel", "exports_files(%r)\n" % (files + ["configuration.bzl"]))

native_artifacts = repository_rule(
    implementation = _native_artifacts_impl,
    local = True,
    configure = True,
    environ = ["MTGO_NATIVE_ARTIFACTS"],
)
