"""Discover Apple developer tools on macOS or an OSXCross toolchain on Linux."""

def _execute(ctx, command, description):
    result = ctx.execute(command)
    if result.return_code or not result.stdout.strip():
        fail(description + "\n" + result.stdout + result.stderr)
    return result.stdout

def _macos_sdk_impl(ctx):
    if ctx.os.name == "linux":
        cross_root = ctx.os.environ.get("OSXCROSS_ROOT", "")
        if not cross_root:
            fail("Linux runtime builds require OSXCross; set OSXCROSS_ROOT to its target directory.")
        xcrun = cross_root + "/bin/xcrun"
        sdk_path = _execute(ctx, [xcrun, "--show-sdk-path"], "Could not locate the OSXCross macOS SDK.").strip()
        clang = _execute(ctx, [xcrun, "--find", "clang"], "Could not locate the OSXCross compiler.").strip()
        version = _execute(ctx, [clang, "--version"], "Could not read the OSXCross compiler version.")
        for tool in ["cmake", "ninja", "bison", "m4", "pkg-config", "gcc", "make"]:
            version += _execute(ctx, ["/usr/bin/" + tool, "--version"], "Could not identify the Linux build utility: " + tool)

        version += _execute(ctx, ["/usr/bin/pkg-config", "--modversion", "freetype2"], "Wine host tools require Linux FreeType development files.")

        configuration = _execute(ctx, [cross_root + "/bin/osxcross-conf"], "Could not read the OSXCross configuration.")
        resource_dir = _execute(ctx, [clang, "-print-resource-dir"], "Could not locate the Clang resource directory.").strip()
        runtime = resource_dir + "/lib/darwin/libclang_rt.osx.a"
        runtime_hash = _execute(ctx, ["/usr/bin/sha256sum", runtime], "The Darwin compiler runtime is missing; provide the compiler_rt Docker build context.")
        settings = ctx.read(sdk_path + "/SDKSettings.json")

        ctx.file("toolchain.bzl", "SWIFTC = ''\nSDK_PATH = %r\nBUILD_OS = 'linux'\nCROSS_ROOT = %r\nHOST_ARCH = %r\n" % (
            sdk_path, cross_root, "arm64" if ctx.os.arch in ["aarch64", "arm64"] else "x86_64",
        ))
        ctx.file("fingerprint.txt", version + configuration + runtime_hash + settings)
        ctx.file("BUILD.bazel", 'exports_files(["fingerprint.txt", "toolchain.bzl"])\n')
        return
    if ctx.os.name != "mac os x":
        fail("Build on macOS, or cross-compile the runtime on Linux with OSXCross.")

    xcrun = "/usr/bin/xcrun"
    developer_tools = "Apple developer tools are unavailable. Run xcode-select --install or select an Xcode installation."
    swiftc = _execute(ctx, [xcrun, "--find", "swiftc"], developer_tools).strip()
    sdk_path = _execute(ctx, [xcrun, "--sdk", "macosx", "--show-sdk-path"], developer_tools).strip()
    clang = _execute(ctx, [xcrun, "--find", "clang"], developer_tools).strip()
    version = _execute(ctx, [swiftc, "--version"], "Could not read the Swift compiler version.")
    clang_version = _execute(ctx, [clang, "--version"], "Could not read the Clang compiler version.")
    sdk_version = _execute(ctx, [xcrun, "--sdk", "macosx", "--show-sdk-version"], "Could not read the macOS SDK version.")
    settings_file = sdk_path + "/SDKSettings.plist"
    settings = _execute(ctx, ["/usr/bin/plutil", "-convert", "xml1", "-o", "-", settings_file], "Could not read the macOS SDK settings.")
    ctx.watch(clang)
    ctx.watch(swiftc)
    ctx.watch(settings_file)
    ctx.file("toolchain.bzl", "SWIFTC = %r\nSDK_PATH = %r\nBUILD_OS = 'darwin'\nCROSS_ROOT = ''\nHOST_ARCH = 'arm64'\n" % (swiftc, sdk_path))
    ctx.file("fingerprint.txt", version + clang_version + sdk_version + sdk_path + "\n" + settings)
    ctx.file("BUILD.bazel", 'exports_files(["fingerprint.txt", "toolchain.bzl"])\n')

macos_sdk = repository_rule(
    implementation = _macos_sdk_impl,
    local = True,
    configure = True,
    environ = ["DEVELOPER_DIR", "SDKROOT", "OSXCROSS_ROOT"],
)
