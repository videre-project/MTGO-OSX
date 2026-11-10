"""Run native launcher and MTGO integration checks in isolated sessions."""

load("//tools:macos.bzl", "MacOSApplicationInfo", "RuntimeArchiveInfo")
load("//third_party:native.bzl", "NativeBuildInfo")

def _quote(value):
    return "'" + value.replace("'", "'\\''") + "'"

def _windows_fixture_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".exe")
    ctx.actions.run_shell(
        inputs = [ctx.file.src, ctx.attr.compiler[NativeBuildInfo].root],
        outputs = [output],
        command = "\n".join([
            "set -eu",
            '%s -Os -Wall -Wextra -Werror -nostdlib -Wl,--entry,mainCRTStartup -Wl,--subsystem,console %s -lkernel32 -lshell32 -luser32 -ladvapi32 -o %s' % (_quote(ctx.attr.compiler[NativeBuildInfo].root.path + "/prefix/bin/" + ("aarch64" if ctx.attr.architecture == "arm64" else "x86_64") + "-w64-mingw32-clang"), _quote(ctx.file.src.path), _quote(output.path)),
        ]),
        mnemonic = "CompileWindowsFixture",
        execution_requirements = {"requires-darwin": "1", "no-remote": "1"},
    )
    return [DefaultInfo(files = depset([output]))]

windows_fixture = rule(
    implementation = _windows_fixture_impl,
    attrs = {
        "src": attr.label(mandatory = True, allow_single_file = [".c"]),
        "architecture": attr.string(default = "arm64", values = ["arm64", "x86_64"]),
        "compiler": attr.label(default = "//third_party/llvm_mingw:llvm_mingw", providers = [NativeBuildInfo]),
    },
)

def _dock_attention_test_impl(ctx):
    files = [ctx.executable.observer, ctx.file.runtime, ctx.file.window]
    paths = ['"$TEST_SRCDIR/%s/%s"' % (ctx.workspace_name, file.short_path) for file in files]
    ctx.actions.write(ctx.outputs.executable, "#!/bin/sh\nset -eu\nexec " + " ".join(paths) + "\n", is_executable = True)
    return [DefaultInfo(executable = ctx.outputs.executable, runfiles = ctx.runfiles(files = files))]

dock_attention_test = rule(
    implementation = _dock_attention_test_impl,
    test = True,
    attrs = {
        "observer": attr.label(mandatory = True, executable = True, cfg = "target"),
        "runtime": attr.label(mandatory = True, allow_single_file = True),
        "window": attr.label(mandatory = True, allow_single_file = [".exe"]),
    },
)

def _settings_test_impl(ctx):
    bundle = ctx.attr.app[MacOSApplicationInfo].bundle
    observer = ctx.executable.observer
    prefix = '"$TEST_SRCDIR/' + ctx.workspace_name + '/'
    ctx.actions.write(
        ctx.outputs.executable,
        '#!/bin/sh\nset -eu\nexec ' + prefix + observer.short_path + '" ' + prefix + bundle.short_path + '/Contents/Resources"\n',
        is_executable = True,
    )
    return [DefaultInfo(executable = ctx.outputs.executable, runfiles = ctx.runfiles(files = [observer, bundle]))]

settings_test = rule(
    implementation = _settings_test_impl,
    test = True,
    attrs = {
        "observer": attr.label(mandatory = True, executable = True, cfg = "target"),
        "app": attr.label(mandatory = True, providers = [MacOSApplicationInfo]),
    },
)

def _startup_test_impl(ctx, launcher_only):
    bundle = ctx.attr.app[MacOSApplicationInfo].bundle
    observer = ctx.file.observer
    launcher_observer = ctx.executable.launcher_observer
    runtime = ctx.file.runtime
    archive = ctx.attr.runtime_archive[RuntimeArchiveInfo].archive
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = ctx.outputs.executable,
        substitutions = {
            "%WORKSPACE%": ctx.workspace_name,
            "%APP%": bundle.short_path,
            "%RUNTIME%": runtime.short_path,
            "%RUNTIME_ARCHIVE%": archive.short_path,
            "%ARCHITECTURE%": ctx.attr.architecture,
            "%OBSERVER%": observer.short_path if observer else "",
            "%LAUNCHER_OBSERVER%": launcher_observer.short_path,
            "%LAUNCHER_ONLY%": "true" if launcher_only else "false",
        },
        is_executable = True,
    )
    files = [bundle, runtime, archive, launcher_observer] + ctx.files._specification + ([observer] if observer else [])
    return [DefaultInfo(executable = ctx.outputs.executable, runfiles = ctx.runfiles(files = files))]

def _startup_test_attrs(launcher_only):
    return {
        "app": attr.label(mandatory = True, providers = [MacOSApplicationInfo]),
        "architecture": attr.string(default = "arm64", values = ["arm64", "x86_64"]),
        "runtime": attr.label(default = "//src:runtime", allow_single_file = True),
        "runtime_archive": attr.label(default = "//src:runtime_arm64", providers = [RuntimeArchiveInfo]),
        "observer": attr.label(mandatory = not launcher_only, allow_single_file = [".exe"]),
        "launcher_observer": attr.label(default = "//tests:launcher_observer", executable = True, cfg = "target"),
        "_runner": attr.label(default = "//tests:integration/run.py", allow_single_file = True),
        "_specification": attr.label(default = "//tests:startup_specification"),
    }

def _mtgo_startup_test_impl(ctx):
    return _startup_test_impl(ctx, launcher_only = False)

def _launcher_integration_test_impl(ctx):
    return _startup_test_impl(ctx, launcher_only = True)

mtgo_startup_test = rule(
    implementation = _mtgo_startup_test_impl,
    test = True,
    attrs = _startup_test_attrs(False),
)

launcher_integration_test = rule(
    implementation = _launcher_integration_test_impl,
    test = True,
    attrs = _startup_test_attrs(True),
)
