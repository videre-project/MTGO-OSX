"""Build the Swift application, package native runtimes and create the DMG.

Uses Apple's installed Swift compiler and SDK, tracking their fingerprints in
build inputs. Compilation, signing and disk image creation run on the Mac host.
"""

load("@macos_sdk//:toolchain.bzl", "SDK_PATH", "SWIFTC")
load("//third_party:native.bzl", "NativeBuildInfo")

MacOSApplicationInfo = provider(fields = ["bundle"])
RuntimeBundleInfo = provider(fields = ["archive"])
RuntimeArchiveInfo = provider(fields = ["archive", "catalog"])

# Build uses a development version; Release stamps the selected tag before signing.
DEVELOPMENT_VERSION = "0.0.0"

def _quote(value):
    return "'" + value.replace("'", "'\\''") + "'"

def _compile_swift(ctx, binary, architecture = "arm64"):
    if not SWIFTC:
        fail("Swift launcher targets require macOS. Linux supports the third_party runtime targets.")
    modules = ctx.actions.declare_directory(ctx.label.name + "." + architecture + ".module-cache")
    args = ctx.actions.args()
    args.add_all([
        "-parse-as-library", "-swift-version", "5", "-O",
        "-sdk", SDK_PATH,
        "-target", architecture + "-apple-macos13.0",
        "-module-cache-path", modules.path,
        "-module-name", "MTGOOSX",
    ])
    args.add_all(ctx.files.srcs)
    args.add_all(["-o", binary.path])
    ctx.actions.run(
        executable = SWIFTC,
        arguments = [args],
        inputs = ctx.files.srcs + [ctx.file._fingerprint],
        outputs = [binary, modules],
        mnemonic = "SwiftCompileMacOS",
        execution_requirements = {"requires-darwin": "1", "no-remote": "1"},
    )

def _macos_application_impl(ctx):
    binary = ctx.actions.declare_file(ctx.label.name + ".bin")
    bundle = ctx.actions.declare_directory(ctx.label.name + ".app")
    slices = []
    for architecture in ctx.attr.architectures:
        if architecture not in ["arm64", "x86_64"]:
            fail("Unsupported macOS architecture: " + architecture)
        thin = ctx.actions.declare_file(ctx.label.name + "." + architecture + ".bin")
        _compile_swift(ctx, thin, architecture)
        slices.append(thin)
    ctx.actions.run(
        executable = "/usr/bin/lipo",
        arguments = ["-create"] + [thin.path for thin in slices] + ["-output", binary.path],
        inputs = slices,
        outputs = [binary],
        mnemonic = "MergeMacOSArchitectures",
        execution_requirements = {"requires-darwin": "1", "no-remote": "1"},
    )
    commands = [
        "set -eu",
        "mkdir -p %s/Contents/MacOS %s/Contents/Resources" % (_quote(bundle.path), _quote(bundle.path)),
        "cp %s %s/Contents/MacOS/MTGO" % (_quote(binary.path), _quote(bundle.path)),
        "cp %s %s/Contents/Info.plist" % (_quote(ctx.file.infoplist.path), _quote(bundle.path)),
        "/usr/bin/plutil -insert CFBundleShortVersionString -string %s %s/Contents/Info.plist" % (_quote(DEVELOPMENT_VERSION), _quote(bundle.path)),
        "/usr/bin/plutil -insert CFBundleVersion -string 0 %s/Contents/Info.plist" % _quote(bundle.path),
        "/usr/bin/plutil -lint %s/Contents/Info.plist" % _quote(bundle.path),
        "printf APPL'????' > %s/Contents/PkgInfo" % _quote(bundle.path),
        "cp %s %s/Contents/Resources/RuntimePackages.json" % (_quote(ctx.file.runtime_catalog.path), _quote(bundle.path)),
    ]
    for resource in ctx.files.runtime_files:
        if resource.is_directory:
            # Wine uses wine.inf's modification time to decide whether to update a prefix.
            commands.append("/usr/bin/python3 %s %s %s/Contents/Resources/Runtime" % (_quote(ctx.file._copy_tree.path), _quote(resource.path), _quote(bundle.path)))
            continue
        fail("Runtime packaging must supply a bundle directory.")
    for resource in ctx.files.launcher_files:
        commands.append("mkdir -p %s/Contents/Resources/Launcher" % _quote(bundle.path))
        commands.append("cp -RL %s/. %s/Contents/Resources/Launcher/" % (_quote(resource.path), _quote(bundle.path)))
    for resource in ctx.files.branding:
        prefix = ctx.label.package + "/Resources/"
        if not resource.short_path.startswith(prefix):
            fail("App assets must be declared below its Resources directory.")
        relative = resource.short_path[len(prefix):]
        destination = bundle.path + "/Contents/Resources/" + relative
        parent = destination.rsplit("/", 1)[0]
        commands.append("mkdir -p %s && cp -p %s %s" % (_quote(parent), _quote(resource.path), _quote(destination)))
    for file in ctx.files._license_files:
        commands.append("cp %s %s/Contents/Resources/%s" % (_quote(file.path), _quote(bundle.path), _quote(file.basename)))
    if ctx.attr.allow_rosetta:
        commands.append("/usr/bin/plutil -replace LSRequiresNativeExecution -bool NO %s/Contents/Info.plist" % _quote(bundle.path))
    commands.append("/usr/bin/codesign --force --sign - --timestamp=none %s" % _quote(bundle.path))
    ctx.actions.run_shell(
        inputs = [binary, ctx.file.infoplist, ctx.file._copy_tree, ctx.file.runtime_catalog] + ctx.files.runtime_files + ctx.files.launcher_files + ctx.files.branding + ctx.files._license_files,
        outputs = [bundle],
        command = "\n".join(commands),
        mnemonic = "BundleMacOSApplication",
        execution_requirements = {"requires-darwin": "1", "no-remote": "1"},
    )
    runner = ctx.outputs.executable
    ctx.actions.write(
        runner,
        "#!/bin/bash\nset -euo pipefail\napp=$(cd -P \"${RUNFILES_DIR:-$0.runfiles}/%s/%s\" && pwd -P)\nexec /usr/bin/open \"$app\" --args \"$@\"\n" % (ctx.workspace_name, bundle.short_path),
        is_executable = True,
    )
    return [
        DefaultInfo(files = depset([bundle, runner]), executable = runner, runfiles = ctx.runfiles(files = [bundle])),
        MacOSApplicationInfo(bundle = bundle),
    ]

macos_application = rule(
    implementation = _macos_application_impl,
    executable = True,
    attrs = {
        "srcs": attr.label_list(allow_files = [".swift"], mandatory = True),
        "infoplist": attr.label(allow_single_file = [".plist"], mandatory = True),
        "branding": attr.label(mandatory = True),
        "_copy_tree": attr.label(default = "//tools:copy_tree.py", allow_single_file = [".py"]),
        "architectures": attr.string_list(default = ["arm64", "x86_64"]),
        "allow_rosetta": attr.bool(default = False),
        "runtime_catalog": attr.label(allow_single_file = [".json"], mandatory = True),
        "runtime_files": attr.label(allow_files = True),
        "launcher_files": attr.label(mandatory = True),
        "_license_files": attr.label_list(default = ["//:LICENSE", "//:NOTICE"], allow_files = True),
        "_fingerprint": attr.label(default = "@macos_sdk//:fingerprint.txt", allow_single_file = True),
    },
)

def _macos_dmg_impl(ctx):
    app = ctx.attr.app[MacOSApplicationInfo].bundle
    artwork = ctx.actions.declare_directory(ctx.label.name + ".artwork")
    ctx.actions.run(
        executable = ctx.executable.renderer,
        arguments = [ctx.file.artwork.path, artwork.path],
        inputs = [ctx.file.artwork],
        outputs = [artwork],
        mnemonic = "DrawDiskImageArtwork",
        execution_requirements = {"requires-darwin": "1", "no-remote": "1"},
    )
    image = ctx.actions.declare_file(ctx.label.name + ".dmg")
    wheels = [file for file in ctx.files._wheels if file.basename == "source.archive"]

    # Release can create a DMG from these inputs without running Bazel or Swift.
    packaging = ctx.actions.declare_directory(ctx.label.name + ".inputs")
    commands = [
        "set -eu",
        "mkdir -p %s/wheels" % _quote(packaging.path),
        "cp %s/background.tiff %s/layout.json %s/" % (_quote(artwork.path), _quote(artwork.path), _quote(packaging.path)),
    ]
    for index, wheel in enumerate(wheels):
        commands.append("cp %s %s/wheels/%d.whl" % (_quote(wheel.path), _quote(packaging.path), index))
    ctx.actions.run_shell(
        inputs = [artwork] + wheels,
        outputs = [packaging],
        command = "\n".join(commands),
        mnemonic = "PrepareDiskImageInputs",
    )
    args = ctx.actions.args()
    args.add(ctx.file._builder.path)
    args.add("--app", app.path)
    args.add("--artwork", artwork.path)
    args.add("--output", image.path)
    for wheel in wheels:
        args.add("--wheel", wheel.path)
    ctx.actions.run(
        executable = "/usr/bin/python3",
        arguments = [args],
        inputs = [app, artwork, ctx.file._builder] + wheels,
        outputs = [image],
        mnemonic = "CreateMacOSDiskImage",
        # DiskImages needs the host service; it cannot operate inside sandbox-exec.
        execution_requirements = {"requires-darwin": "1", "no-remote": "1", "no-sandbox": "1"},
    )
    return [
        DefaultInfo(files = depset([image])),
        OutputGroupInfo(release_inputs = depset([packaging])),
    ]

macos_dmg = rule(
    implementation = _macos_dmg_impl,
    attrs = {
        "app": attr.label(mandatory = True, providers = [MacOSApplicationInfo]),
        "artwork": attr.label(mandatory = True, allow_single_file = [".png"]),
        "renderer": attr.label(mandatory = True, executable = True, cfg = "exec"),
        "_builder": attr.label(default = "//tools:dmg.py", allow_single_file = [".py"]),
        "_wheels": attr.label_list(default = [
            "@mtgo_dmgbuild//:source", "@mtgo_ds_store//:source", "@mtgo_mac_alias//:source",
        ]),
    },
)

def _macos_tool_impl(ctx):
    binary = ctx.outputs.executable
    _compile_swift(ctx, binary)
    return [DefaultInfo(executable = binary)]

macos_tool = rule(
    implementation = _macos_tool_impl,
    executable = True,
    attrs = {
        "srcs": attr.label_list(allow_files = [".swift"], mandatory = True),
        "_fingerprint": attr.label(default = "@macos_sdk//:fingerprint.txt", allow_single_file = True),
    },
)

macos_test = rule(
    implementation = _macos_tool_impl,
    test = True,
    attrs = {
        "srcs": attr.label_list(allow_files = [".swift"], mandatory = True),
        "_fingerprint": attr.label(default = "@macos_sdk//:fingerprint.txt", allow_single_file = True),
    },
)

def _runtime_bundle_impl(ctx):
    wine = ctx.attr.wine[NativeBuildInfo].root
    sevenzip = ctx.attr.sevenzip[NativeBuildInfo].root
    llvm_mingw = ctx.attr._llvm_mingw[NativeBuildInfo].root
    bundle = ctx.actions.declare_directory(ctx.label.name)
    archive = ctx.actions.declare_file(ctx.label.name + ".tar.xz")
    app = bundle.path + "/MTGO.app"
    resources = app + "/Contents/Resources"
    wine_arch = "aarch64" if ctx.attr.architecture == "arm64" else "x86_64"
    unix = resources + "/lib/wine/" + wine_arch + "-unix"
    windows = resources + "/lib/wine/" + wine_arch + "-windows"
    inputs = [wine, sevenzip, llvm_mingw, ctx.file.manifest, ctx.file.infoplist, ctx.file.icon, ctx.file._copy_tree, ctx.file._sign_runtime]
    commands = [
        "set -eu",
        "mkdir -p %s/Contents/MacOS %s" % (_quote(app), _quote(resources)),
        "/usr/bin/python3 %s %s/prefix %s" % (_quote(ctx.file._copy_tree.path), _quote(wine.path), _quote(resources)),
        "chmod -R u+w %s" % _quote(bundle.path),
        "/usr/bin/find %s -name '*.a' -delete" % _quote(resources),
        # Wine's Windows directory also contains PE drivers, controls and type libraries.
        "/usr/bin/find %s -type f -exec %s/prefix/bin/llvm-strip --strip-all {} +" % (_quote(windows), _quote(llvm_mingw.path)),
        "mv %s/wine %s/Contents/MacOS/wine" % (_quote(unix), _quote(app)),
        "ln -s ../../../../MacOS/wine %s/wine" % _quote(unix),
        "ln -s ../Resources/lib/wine/%s-unix/ntdll.so %s/Contents/MacOS/ntdll.so" % (wine_arch, _quote(app)),
        "cp %s/prefix/7zz %s/bin/7zz" % (_quote(sevenzip.path), _quote(resources)),
        "cp %s %s/Contents/Info.plist" % (_quote(ctx.file.infoplist.path), _quote(app)),
        "cp %s %s/GameIcon.icns" % (_quote(ctx.file.icon.path), _quote(resources)),
        "printf APPL'????' > %s/Contents/PkgInfo" % _quote(app),
        "/usr/bin/plutil -lint %s/Contents/Info.plist" % _quote(app),
        "/usr/bin/python3 %s %s/Licenses %s/Licenses" % (_quote(ctx.file._copy_tree.path), _quote(wine.path), _quote(bundle.path)),
        "/usr/bin/python3 %s %s/Licenses %s/Licenses" % (_quote(ctx.file._copy_tree.path), _quote(sevenzip.path), _quote(bundle.path)),
    ]
    if ctx.attr.d3d9:
        d3d9 = ctx.attr.d3d9[NativeBuildInfo].root
        inputs.append(d3d9)
        commands.extend([
            "mkdir -p %s/lib/dxvk" % _quote(resources),
            "cp %s/prefix/lib/d3d9.dll %s/lib/dxvk/d3d9.dll" % (_quote(d3d9.path), _quote(resources)),
            "%s/prefix/bin/llvm-strip --strip-all %s/lib/dxvk/d3d9.dll" % (_quote(llvm_mingw.path), _quote(resources)),
            "/usr/bin/python3 %s %s/Licenses %s/Licenses" % (_quote(ctx.file._copy_tree.path), _quote(d3d9.path), _quote(bundle.path)),
        ])
    commands.extend([
        "/usr/bin/python3 %s %s %s" % (_quote(ctx.file._sign_runtime.path), _quote(app), _quote(ctx.attr.architecture)),
        "/usr/bin/codesign --force --sign - --timestamp=none %s" % _quote(app),
        "/usr/bin/codesign --verify --deep --strict %s" % _quote(app),
        "cp %s %s/runtime.json" % (_quote(ctx.file.manifest.path), _quote(bundle.path)),
        # Directory cache restoration can dereference symlinks; archive the signed bundle now.
        "COPYFILE_DISABLE=1 /usr/bin/tar --format=pax -cJf %s -C %s ." % (_quote(archive.path), _quote(bundle.path)),
    ])
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [bundle, archive],
        command = "\n".join(commands),
        mnemonic = "BundleNativeWineRuntime",
        execution_requirements = {"requires-darwin": "1", "no-remote": "1"},
    )
    return [
        DefaultInfo(files = depset([bundle])),
        RuntimeBundleInfo(archive = archive),
    ]

runtime_bundle = rule(
    implementation = _runtime_bundle_impl,
    attrs = {
        "architecture": attr.string(default = "arm64", values = ["arm64", "x86_64"]),
        "_sign_runtime": attr.label(default = "//tools:sign_runtime.py", allow_single_file = [".py"]),
        "wine": attr.label(mandatory = True, providers = [NativeBuildInfo]),
        "sevenzip": attr.label(mandatory = True, providers = [NativeBuildInfo]),
        "_llvm_mingw": attr.label(default = "//third_party/llvm_mingw:llvm_mingw", providers = [NativeBuildInfo]),
        "d3d9": attr.label(providers = [NativeBuildInfo]),
        "manifest": attr.label(mandatory = True, allow_single_file = [".json"]),
        "infoplist": attr.label(mandatory = True, allow_single_file = [".plist"]),
        "icon": attr.label(mandatory = True, allow_single_file = [".icns"]),
        "_copy_tree": attr.label(default = "//tools:copy_tree.py", allow_single_file = [".py"]),
    },
)


def _runtime_archive_impl(ctx):
    runtime = ctx.attr.runtime[RuntimeBundleInfo].archive
    filename = "runtime-%s-macos-%s.tar.xz" % (ctx.attr.version, ctx.attr.architecture)
    archive = ctx.actions.declare_file(filename)
    catalog = ctx.actions.declare_file(ctx.label.name + ".json")
    metadata = json.encode({
        "schemaVersion": 1,
        "packages": [{
            "version": ctx.attr.version,
            "architecture": ctx.attr.architecture,
            "url": ctx.attr.release_url.rstrip("/") + "/v" + DEVELOPMENT_VERSION + "/" + filename,
            "sha256": "@SHA256@",
        }],
    })
    ctx.actions.run_shell(
        inputs = [runtime],
        outputs = [archive, catalog],
        command = "\n".join([
            "set -eu",
            "cp %s %s" % (_quote(runtime.path), _quote(archive.path)),
            "checksum=$(/usr/bin/shasum -a 256 %s | /usr/bin/cut -d ' ' -f 1)" % _quote(archive.path),
            "printf '%%s\n' %s | /usr/bin/sed \"s/@SHA256@/$checksum/\" > %s" % (_quote(metadata), _quote(catalog.path)),
        ]),
        mnemonic = "ArchiveWineRuntime",
        execution_requirements = {"requires-darwin": "1", "no-remote": "1"},
    )
    return [
        DefaultInfo(files = depset([archive])),
        OutputGroupInfo(catalog = depset([catalog])),
        RuntimeArchiveInfo(archive = archive, catalog = catalog),
    ]

runtime_archive = rule(
    implementation = _runtime_archive_impl,
    attrs = {
        "runtime": attr.label(mandatory = True, providers = [RuntimeBundleInfo]),
        "version": attr.string(mandatory = True),
        "architecture": attr.string(mandatory = True, values = ["arm64", "x86_64"]),
        "release_url": attr.string(mandatory = True),
    },
)


def _runtime_catalog_impl(ctx):
    catalog = ctx.actions.declare_file(ctx.label.name + ".json")
    manifests = [package[RuntimeArchiveInfo].catalog for package in ctx.attr.packages]
    commands = ["set -eu", "printf '%%s' %s > %s" % (_quote('{"schemaVersion":1,"packages":['), _quote(catalog.path))]
    for index, manifest in enumerate(manifests):
        if index:
            commands.append("printf ',' >> %s" % _quote(catalog.path))
        commands.append("/usr/bin/plutil -extract packages.0 json -o - %s >> %s" % (_quote(manifest.path), _quote(catalog.path)))
    commands.append("printf ']}' >> %s" % _quote(catalog.path))
    ctx.actions.run_shell(
        inputs = manifests,
        outputs = [catalog],
        command = "\n".join(commands),
        mnemonic = "AssembleRuntimeCatalog",
        execution_requirements = {"requires-darwin": "1", "no-remote": "1"},
    )
    return [DefaultInfo(files = depset([catalog]))]

runtime_catalog = rule(
    implementation = _runtime_catalog_impl,
    attrs = {"packages": attr.label_list(mandatory = True, providers = [RuntimeArchiveInfo])},
)
