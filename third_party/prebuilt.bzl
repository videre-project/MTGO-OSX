"""Package published libraries with their pinned provenance and license notices."""

load("//third_party:native.bzl", "NativeBuildInfo")

def _prebuilt_library_impl(ctx):
    output = ctx.actions.declare_directory(ctx.label.name)
    args = ctx.actions.args()
    args.add_all([output.path, ctx.file.binary.path, ctx.file.provenance.path, ctx.label.name])
    args.add_all(ctx.files.licenses)
    ctx.actions.run_shell(
        inputs = [ctx.file.binary, ctx.file.provenance] + ctx.files.licenses,
        outputs = [output],
        arguments = [args],
        command = """
set -eu
output="$1"
notices="$output/Licenses/$4"
mkdir -p "$output/prefix/lib" "$notices"
cp "$2" "$output/prefix/lib/"
cp "$3" "$notices/sources.json"
shift 4
cp "$@" "$notices/"
""",
        mnemonic = "PackagePrebuiltLibrary",
    )
    return [DefaultInfo(files = depset([output])), NativeBuildInfo(root = output, library_roots = depset())]

prebuilt_library = rule(
    implementation = _prebuilt_library_impl,
    attrs = {
        "binary": attr.label(mandatory = True, allow_single_file = True),
        "provenance": attr.label(mandatory = True, allow_single_file = [".json"]),
        "licenses": attr.label_list(mandatory = True, allow_files = True),
    },
)
