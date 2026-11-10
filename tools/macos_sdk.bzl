"""Discover the installed Apple SDK, supporting Xcode and Command Line Tools."""

def _execute(ctx, command, description):
    result = ctx.execute(command)
    if result.return_code or not result.stdout.strip():
        fail(description + "\n" + result.stdout + result.stderr)
    return result.stdout

def _macos_sdk_impl(ctx):
    if ctx.os.name != "mac os x":
        fail("MTGO-OSX requires a macOS build host with Apple Command Line Tools or Xcode.")

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
    ctx.file("toolchain.bzl", "SWIFTC = %r\nSDK_PATH = %r\n" % (swiftc, sdk_path))
    ctx.file("fingerprint.txt", version + clang_version + sdk_version + sdk_path + "\n" + settings)
    ctx.file("BUILD.bazel", 'exports_files(["fingerprint.txt", "toolchain.bzl"])\n')

macos_sdk = repository_rule(
    implementation = _macos_sdk_impl,
    local = True,
    configure = True,
    environ = ["DEVELOPER_DIR", "SDKROOT"],
)
