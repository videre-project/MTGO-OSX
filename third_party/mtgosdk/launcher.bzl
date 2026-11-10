"""Extract the published ClickOnce launcher from a pinned MTGOSDK NuGet package."""
load("@dotnet_sdk//:toolchain.bzl", "DOTNET")

def _sdk_launcher_impl(ctx):
    bundle = ctx.actions.declare_directory(ctx.label.name)
    args = ctx.actions.args()
    args.add(DOTNET)
    args.add_all([
        ctx.file._project,
        ctx.file._extractor,
        ctx.file.assembly,
        ctx.file.notice,
        ctx.file.license,
        bundle.path,
    ])
    ctx.actions.run_shell(
        arguments = [args],
        command = """
set -eu
dotnet="$1"
project="$2"
extractor="$3"
assembly="$PWD/$4"
notice="$5"
license="$6"
output="$PWD/$7"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$project" "$extractor" "$work/"
DOTNET_CLI_HOME="$work/dotnet-home" "$dotnet" run \
    --project "$work/ExtractLauncher.csproj" --configuration Release --no-launch-profile \
    -- "$assembly" "$output"
cp "$notice" "$output/MTGOSDK-NOTICE"
cp "$license" "$output/MTGOSDK-LICENSE"
""",
        inputs = [
            ctx.file.assembly,
            ctx.file.notice,
            ctx.file.license,
            ctx.file._project,
            ctx.file._extractor,
            ctx.file._fingerprint,
        ],
        outputs = [bundle],
        use_default_shell_env = True,
        env = {"DOTNET_NOLOGO": "1", "DOTNET_CLI_TELEMETRY_OPTOUT": "1"},
        mnemonic = "ExtractMTGOLauncher",
        execution_requirements = {"requires-darwin": "1", "no-remote": "1"},
    )
    return [DefaultInfo(files = depset([bundle]))]

sdk_launcher = rule(
    implementation = _sdk_launcher_impl,
    attrs = {
        "assembly": attr.label(allow_single_file = [".dll"], mandatory = True),
        "notice": attr.label(allow_single_file = True, mandatory = True),
        "license": attr.label(allow_single_file = True, mandatory = True),
        "_project": attr.label(default = "ExtractLauncher.csproj", allow_single_file = True),
        "_extractor": attr.label(default = "ExtractLauncher.cs", allow_single_file = True),
        "_fingerprint": attr.label(default = "@dotnet_sdk//:fingerprint.txt", allow_single_file = True),
    },
)
