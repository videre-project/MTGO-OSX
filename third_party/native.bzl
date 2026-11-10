"""Cache each upstream dependency as a separate native build action."""

load("@macos_sdk//:toolchain.bzl", "SDK_PATH")

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
    for option in ctx.attr.meson_options:
        args.add("--meson-option=" + option)
    for name, value in [
        ("target", ctx.attr.target),
        ("artifact", ctx.attr.artifact),
        ("artifact-name", ctx.attr.artifact_name),
        ("cross-file", ctx.attr.cross_file),
        ("cflags", ctx.attr.cflags),
    ]:
        if value:
            args.add("--" + name + "=" + value)
    if ctx.file.cmake_project:
        args.add("--cmake-project", ctx.file.cmake_project.path)
        inputs.append(ctx.file.cmake_project)
    # Rosetta supplies the Intel build environment on Apple Silicon; thin ARM64
    # build tools remain executable and shared between the two runtime builds.
    intel = ctx.attr.architecture == "x86_64"
    ctx.actions.run(
        executable = "/usr/bin/arch" if intel else "/usr/bin/python3",
        arguments = ["-x86_64", "/usr/bin/python3", args] if intel else [args],
        inputs = depset(inputs),
        outputs = [output],
        mnemonic = "BuildNativeDependency",
        progress_message = "Building " + str(ctx.label),
        execution_requirements = {"requires-darwin": "1", "no-remote": "1"},
        resource_set = _resources,
    )
    roots = depset([output] if ctx.attr.library else [], transitive = [libraries])
    return [DefaultInfo(files = depset([output])), NativeBuildInfo(root = output, library_roots = roots)]

native_build = rule(
    implementation = _native_build_impl,
    attrs = {
        "architecture": attr.string(default = "arm64", values = ["arm64", "x86_64"]),
        "kind": attr.string(mandatory = True, values = ["archive", "wheel-tools", "autotools", "cmake", "meson", "wine"]),
        "source": attr.label(),
        "sources": attr.label_keyed_string_dict(),
        "deps": attr.label_list(providers = [NativeBuildInfo]),
        "tools": attr.label_keyed_string_dict(providers = [NativeBuildInfo]),
        "patches": attr.label_list(allow_files = [".patch"]),
        "source_patches": attr.string_list(),
        "configure_options": attr.string_list(),
        "cmake_options": attr.string_list(),
        "meson_options": attr.string_list(),
        "target": attr.string(),
        "artifact": attr.string(),
        "artifact_name": attr.string(),
        "cross_file": attr.string(),
        "cflags": attr.string(),
        "cmake_project": attr.label(allow_single_file = [".txt"]),
        "strip_components": attr.int(default = 1),
        "library": attr.bool(default = False),
        "_builder": attr.label(default = "//tools:build_native.py", allow_single_file = True),
        "_copy_tree": attr.label(default = "//tools:copy_tree.py", allow_single_file = True),
        "_fingerprint": attr.label(default = "@macos_sdk//:fingerprint.txt", allow_single_file = True),
    },
)


def native_library(name, deps = [], architecture_options = {}, **kwargs):
    """Build matching native libraries from one recipe for each runtime architecture."""
    for architecture, suffix in [("arm64", ""), ("x86_64", "_x86_64")]:
        options = dict(kwargs)
        options.update(architecture_options.get(architecture, {}))
        native_build(
            name = name + suffix,
            architecture = architecture,
            deps = [dependency + suffix for dependency in deps],
            **options
        )
