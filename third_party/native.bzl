"""Cache each upstream dependency as a separate native build action."""

load("@macos_sdk//:toolchain.bzl", "BUILD_OS", "CROSS_ROOT", "SDK_PATH")

NativeBuildInfo = provider(fields = ["root", "library_roots"])

def _add_source(args, inputs, target, destination):
    files = target[DefaultInfo].files.to_list()
    archives = [file for file in files if file.basename == "source.archive"]
    metadata = [file for file in files if file.basename == "source.json"]
    if len(archives) != 1 or len(metadata) != 1:
        fail("A pinned source must supply its archive and source.json.")
    args.add("--source", destination + "=" + archives[0].path + "=" + metadata[0].path)
    inputs.extend(files)

def _resources(_os, _inputs):
    return {"cpu": 4, "memory": 1024}

def _native_build_impl(ctx):
    output = ctx.actions.declare_directory(ctx.label.name)
    args = ctx.actions.args()
    args.add(ctx.file._builder.path)
    args.add("--name", ctx.label.name)
    args.add("--kind", ctx.attr.kind)
    args.add("--output", output.path)
    args.add("--sdk", SDK_PATH)
    args.add("--architecture", ctx.attr.architecture)
    args.add("--build-jobs", ctx.var.get("native_jobs", "4"))
    args.add("--strip-components", ctx.attr.strip_components)
    inputs = [ctx.file._builder, ctx.file._copy_tree, ctx.file._fingerprint]
    if ctx.attr.source:
        _add_source(args, inputs, ctx.attr.source, "main")
    for target, destination in ctx.attr.sources.items():
        _add_source(args, inputs, target, destination)
    libraries = depset(transitive = [target[NativeBuildInfo].library_roots for target in ctx.attr.deps])
    for root in libraries.to_list():
        args.add("--dependency", root.path)
    inputs.extend(libraries.to_list())
    for target, role in ctx.attr.tools.items():
        # Linux supplies native build utilities; only the Windows compiler is cross-host packaged.
        if BUILD_OS == "linux" and role in ["m4", "bison", "pkgconf", "build_tools"]:
            continue
        root = target[NativeBuildInfo].root
        args.add("--tool", role + "=" + root.path)
        inputs.append(root)
    for file in ctx.files.patches:
        args.add("--patch", file.path + "=.")
        inputs.append(file)
    for patch in ctx.attr.source_patches:
        args.add("--source-patch", patch)
    for option in ctx.attr.configure_options:
        args.add("--configure-option=" + option)
    for option in ctx.attr.cmake_options:
        args.add("--cmake-option=" + option)
    for name, value in [
        ("target", ctx.attr.target),
        ("artifact", ctx.attr.artifact),
        ("artifact-name", ctx.attr.artifact_name),
        ("cflags", ctx.attr.cflags),
    ]:
        if value:
            args.add("--" + name + "=" + value)
    if ctx.file.cmake_project:
        args.add("--cmake-project", ctx.file.cmake_project.path)
        inputs.append(ctx.file.cmake_project)
    # Rosetta supplies the Intel build environment on Apple Silicon; thin ARM64
    # build tools remain executable and shared between the two runtime builds.
    intel = BUILD_OS == "darwin" and ctx.attr.architecture == "x86_64"
    ctx.actions.run(
        executable = "/usr/bin/arch" if intel else "/usr/bin/python3",
        arguments = ["-x86_64", "/usr/bin/python3", args] if intel else [args],
        inputs = depset(inputs),
        outputs = [output],
        mnemonic = "BuildNativeDependency",
        progress_message = "Building " + str(ctx.label),
        env = {"OSXCROSS_ROOT": CROSS_ROOT} if CROSS_ROOT else {},
        execution_requirements = {"no-remote": "1"} | ({"requires-darwin": "1"} if BUILD_OS == "darwin" else {}),
        resource_set = _resources,
    )
    roots = depset([output] if ctx.attr.library else [], transitive = [libraries])
    return [DefaultInfo(files = depset([output])), NativeBuildInfo(root = output, library_roots = roots)]

native_build = rule(
    implementation = _native_build_impl,
    attrs = {
        "architecture": attr.string(default = "arm64", values = ["arm64", "x86_64"]),
        "kind": attr.string(mandatory = True, values = ["archive", "wheel-tools", "autotools", "cmake", "wine"]),
        "source": attr.label(),
        "sources": attr.label_keyed_string_dict(),
        "deps": attr.label_list(providers = [NativeBuildInfo]),
        "tools": attr.label_keyed_string_dict(providers = [NativeBuildInfo]),
        "patches": attr.label_list(allow_files = [".patch"]),
        "source_patches": attr.string_list(),
        "configure_options": attr.string_list(),
        "cmake_options": attr.string_list(),
        "target": attr.string(),
        "artifact": attr.string(),
        "artifact_name": attr.string(),
        "cflags": attr.string(),
        "cmake_project": attr.label(allow_single_file = [".txt"]),
        "strip_components": attr.int(default = 1),
        "library": attr.bool(default = False),
        "_builder": attr.label(default = "//tools:build_native.py", allow_single_file = True),
        "_copy_tree": attr.label(default = "//tools:copy_tree.py", allow_single_file = True),
        "_fingerprint": attr.label(default = "@macos_sdk//:fingerprint.txt", allow_single_file = True),
    },
)


def _imported_native_impl(ctx):
    output = ctx.actions.declare_directory(ctx.label.name)
    ctx.actions.run_shell(
        inputs = [ctx.file.archive],
        outputs = [output],
        arguments = [output.path, ctx.file.archive.path],
        command = """
set -eu
mkdir -p "$1"
tar -xf "$2" -C "$1"
test -d "$1/prefix"
test -d "$1/Licenses"
""",
        mnemonic = "ImportNativeBuild",
        progress_message = "Importing " + str(ctx.label),
    )
    return [DefaultInfo(files = depset([output])), NativeBuildInfo(root = output, library_roots = depset([output]) if ctx.attr.library else depset())]

_imported_native = rule(
    implementation = _imported_native_impl,
    attrs = {
        "archive": attr.label(mandatory = True, allow_single_file = [".tar.gz"]),
        "library": attr.bool(default = False),
    },
)


def native_library(name, deps = [], architecture_options = {}, archives = {}, **kwargs):
    """Build matching native libraries or import archived builds for packaging."""
    for architecture, suffix in [("arm64", ""), ("x86_64", "_x86_64")]:
        if archives:
            _imported_native(
                name = name + suffix,
                archive = archives[architecture],
                library = kwargs.get("library", False),
                visibility = kwargs.get("visibility"),
            )
            continue
        options = dict(kwargs)
        options.update(architecture_options.get(architecture, {}))
        native_build(
            name = name + suffix,
            architecture = architecture,
            deps = [dependency + suffix for dependency in deps],
            **options
        )

def _native_archive_impl(ctx):
    # Cache the archive itself so later transfers reuse the same bytes.
    root = ctx.attr.dependency[NativeBuildInfo].root
    archive = ctx.actions.declare_file("wine-" + ctx.attr.architecture + ".tar.gz")
    ctx.actions.run_shell(
        inputs = [root, ctx.file._copy_tree],
        outputs = [archive],
        arguments = [ctx.file._copy_tree.path, root.path, archive.path],
        command = """
set -eu
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
/usr/bin/python3 "$1" "$2" "$staging"
chmod -R u+w "$staging"
tar --format=pax --exclude=Logs -czf "$3" -C "$staging" .
""",
        mnemonic = "ArchiveNativeBuild",
    )
    return [DefaultInfo(files = depset([archive]))]

native_archive = rule(
    implementation = _native_archive_impl,
    attrs = {
        "dependency": attr.label(mandatory = True, providers = [NativeBuildInfo]),
        "architecture": attr.string(mandatory = True, values = ["arm64", "x86_64"]),
        "_copy_tree": attr.label(default = "//tools:copy_tree.py", allow_single_file = [".py"]),
    },
)
