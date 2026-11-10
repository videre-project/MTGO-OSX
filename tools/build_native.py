#!/usr/bin/env python3
"""Run one upstream native build for a declared Bazel dependency."""

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import zipfile

from copy_tree import copy_tree


def run(command, *, cwd=None, env=None, log=None):
    command = [str(arg) for arg in command]
    started = time.monotonic()
    if log:
        print("+ " + shlex.join(command), file=log, flush=True)
    try:
        subprocess.run(command, cwd=cwd, env=env,
                       stdout=log, stderr=subprocess.STDOUT if log else None, check=True)
    except subprocess.CalledProcessError:
        if log:
            log.flush()
            print("\n".join(Path(log.name).read_text(errors="replace").splitlines()[-60:]), flush=True)
        raise
    finally:
        if log:
            print(f"# Elapsed: {time.monotonic() - started:.1f}s", file=log, flush=True)


def macos_tool(name, architecture):
    """Select a host executable that emits or inspects the requested macOS architecture."""
    if platform.system() == "Darwin":
        if name in ("clang", "clang++"):
            return subprocess.check_output(["/usr/bin/xcrun", "--find", name], text=True).strip()
        return "/usr/bin/" + name

    cross_root = Path(os.environ["OSXCROSS_ROOT"])
    pattern = re.compile(re.escape(architecture) + r"-apple-darwin[0-9.]+-" + re.escape(name))
    matches = [file for file in (cross_root / "bin").iterdir() if pattern.fullmatch(file.name)]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one OSXCross {name} for {architecture}: {matches}")
    return str(matches[0])


def extract(archive, destination, strip=1):
    destination.mkdir(parents=True, exist_ok=True)
    run(["/usr/bin/tar", "-xf", archive, "-C", destination, "--strip-components=" + str(strip)])


def copy_licenses(source, destination):
    for file in source.iterdir():
        if file.name.lower().startswith(("license", "copying", "copyright", "notice")):
            destination.mkdir(parents=True, exist_ok=True)
            copy_tree(file, destination / file.name, writable=True)


def normalize_libraries(prefix, architecture, env):
    """Keep native install names and loader paths independent of build directories."""
    library_dir = prefix / "lib"
    for file in prefix.rglob("*"):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open("rb") as stream:
            if stream.read(4) not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
                continue
        changes = []
        linked = subprocess.check_output([macos_tool("otool", architecture), "-L", file], text=True, env=env)
        for line in linked.splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                changes += ["-change", dependency, "@rpath/" + Path(dependency).name]
        if file.parent == library_dir and file.suffix == ".dylib":
            changes += ["-id", "@rpath/" + file.name]
        commands = subprocess.check_output([macos_tool("otool", architecture), "-l", file], text=True, env=env)
        for path in re.findall(r"\n\s+path (.+) \(offset \d+\)", commands):
            if path.startswith("/") and not path.startswith(("/usr/lib", "/System/Library")):
                changes += ["-delete_rpath", path]
        relative = os.path.relpath(library_dir, file.parent)
        rpath = "@loader_path" + ("/" + relative if relative != "." else "")
        if "path " + rpath + " (offset " not in commands:
            changes += ["-add_rpath", rpath]
        if changes:
            run([macos_tool("install_name_tool", architecture), *changes, file], env=env)
        # Signing happens on macOS after cross-built binaries have been transferred.
        if platform.system() == "Darwin":
            run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", file])
        run([macos_tool("lipo", architecture), file, "-verify_arch", architecture], env=env)


def wheel_tools(sources, prefix):
    for name, (archive, _) in sources.items():
        with zipfile.ZipFile(archive) as wheel:
            wheel.extractall(prefix / name)
    binaries = prefix / "bin"
    binaries.mkdir()
    for name, pattern in [("cmake", "cmake/data/bin/cmake"), ("ninja", "*.data/scripts/ninja")]:
        matches = list((prefix / name).glob(pattern))
        if len(matches) != 1:
            raise RuntimeError("Unexpected build-tool wheel layout: " + name)
        executable = matches[0]
        executable.chmod(0o755)
        (binaries / name).symlink_to(os.path.relpath(executable, binaries))


def build(args):
    cross_compile = platform.system() == "Linux"
    if not cross_compile and (platform.system() != "Darwin" or platform.machine() != args.architecture):
        raise RuntimeError("Run on the requested macOS architecture, or use OSXCross on Linux.")
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    prefix = output / "prefix"
    prefix.mkdir()
    sources = {}
    for item in args.source:
        name, archive, metadata = item.split("=", 2)
        sources[name] = (Path(archive).resolve(), json.loads(Path(metadata).read_text()))
    tools = {name: Path(root).resolve() / "prefix" for name, root in (item.split("=", 1) for item in args.tool)}
    roots = [Path(root).resolve() for root in args.dependency]
    provenance = {name: metadata for name, (_, metadata) in sources.items()}
    if args.kind == "wheel-tools":
        wheel_tools(sources, prefix)
    elif args.kind == "archive":
        extract(sources["main"][0], prefix, args.strip_components)
        copy_licenses(prefix, output / "Licenses" / args.name)
    else:
        with tempfile.TemporaryDirectory(prefix="mtgo-" + args.name + "-") as temporary:
            root = Path(temporary)
            source = root / "source"
            dependencies = root / "dependencies"
            dependencies.mkdir()
            for dependency in roots:
                copy_tree(dependency / "prefix", dependencies, writable=True)
                if (dependency / "Licenses").is_dir():
                    copy_tree(dependency / "Licenses", output / "Licenses", writable=True)
            extract(sources["main"][0], source)
            for name, (archive, _) in sources.items():
                if name == "main":
                    continue
                destination = source / name
                if destination.exists():
                    destination.rmdir()
                extract(archive, destination)
            logs = output / "Logs"
            logs.mkdir()
            with (logs / "build.log").open("w") as log:
                for item in args.source_patch:
                    file, directory = item.split("=", 1)
                    run(["/usr/bin/patch", "-p1", "--batch", "--fuzz=0", "-i", source / file], cwd=source / directory, log=log)
                for item in args.patch:
                    file, directory = item.split("=", 1)
                    run(["/usr/bin/patch", "-p1", "--batch", "--fuzz=0", "-i", Path(file).resolve()], cwd=source / directory, log=log)
                compiler = macos_tool("clang", args.architecture)
                env = dict(os.environ, LC_ALL="C", LANG="C", MACOSX_DEPLOYMENT_TARGET="13.0", SDKROOT=args.sdk)
                tool_paths = [str(tool / "bin") for tool in tools.values()]
                if cross_compile:
                    tool_paths = [str(Path(os.environ["OSXCROSS_ROOT"]) / "bin"), "/usr/lib/llvm-18/bin"] + tool_paths
                    tools["build_tools"] = Path("/usr")
                env["PATH"] = ":".join(tool_paths + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
                env["CC"] = compiler
                env["CXX"] = macos_tool("clang++", args.architecture)
                env["OBJC"] = compiler
                env["OBJCXX"] = env["CXX"]
                env["CFLAGS"] = "-O2 -g -arch " + args.architecture + " -mmacosx-version-min=13.0" + (" " + args.cflags if args.cflags else "")
                env["CXXFLAGS"] = "-O2 -g -arch " + args.architecture + " -mmacosx-version-min=13.0"
                env["CPPFLAGS"] = "-I" + str(dependencies / "include")
                env["LDFLAGS"] = "-L" + str(dependencies / "lib") + " -Wl,-rpath," + str(dependencies / "lib")
                env["PKG_CONFIG_PATH"] = str(dependencies / "lib/pkgconfig")
                if cross_compile:
                    env["PKG_CONFIG_LIBDIR"] = env["PKG_CONFIG_PATH"]
                    env["PKG_CONFIG"] = "/usr/bin/pkg-config"
                    for name in ("ar", "ranlib", "nm", "strip", "ld", "otool"):
                        env[name.upper()] = macos_tool(name, args.architecture)
                if "pkgconf" in tools:
                    env["PKG_CONFIG"] = str(tools["pkgconf"] / "bin/pkgconf")
                work = root / "build"
                work.mkdir()
                if args.kind in ("autotools", "wine"):
                    configure = [source / "configure", *args.configure_option]
                    if cross_compile:
                        build_triple = subprocess.check_output(["/usr/bin/gcc", "-dumpmachine"], text=True).strip()
                        target = ("aarch64" if args.architecture == "arm64" else "x86_64") + "-apple-darwin"
                        configure += ["--build=" + build_triple, "--host=" + target]
                        if args.kind == "wine":
                            # Wine executes generated tools during the target build; those must run on Linux.
                            host_tools = root / "host-tools"
                            host_tools.mkdir()
                            host_environment = dict(os.environ, PATH=env["PATH"], LC_ALL="C")
                            run([
                                source / "configure", "--enable-archs=none", "--without-x",
                                "--without-wayland", "--disable-tests",
                            ], cwd=host_tools, env=host_environment, log=log)
                            # The resource compiler locates its locale data beside the host tools.
                            run(["make", "-j" + str(args.build_jobs), "__tooldeps__", "nls/all"],
                                cwd=host_tools, env=host_environment, log=log)
                            configure += ["--with-wine-tools=" + str(host_tools)]
                    if args.kind == "wine":
                        configure += ["--prefix=/Runtime", "--libdir=/Runtime/lib"]
                    else:
                        configure += ["--prefix=" + str(prefix)]
                    run(configure, cwd=work, env=env, log=log)
                    run(["make", "-j" + str(args.build_jobs)], cwd=work, env=env, log=log)
                    install = ["make", "install"]
                    if args.kind == "wine":
                        install += ["DESTDIR=" + str(root / "stage")]
                    run(install, cwd=work, env=env, log=log)
                    if args.kind == "wine":
                        prefix.rmdir()
                        shutil.move(str(root / "stage/Runtime"), prefix)
                        for library in (dependencies / "lib").glob("*.dylib"):
                            copy_tree(library, prefix / "lib" / library.name, writable=True)
                        for directory in (prefix / "include", prefix / "share/man"):
                            if directory.exists():
                                shutil.rmtree(directory)
                        strip = tools["llvm_mingw"] / "bin/llvm-strip"
                        for file in prefix.rglob("*"):
                            if file.is_file() and file.suffix.lower() in (".dll", ".exe", ".sys"):
                                run([strip, "--strip-debug", file], log=log)
                elif args.kind == "cmake":
                    cmake = tools["build_tools"] / "bin/cmake"
                    options = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0", "-DCMAKE_OSX_ARCHITECTURES=" + args.architecture, *args.cmake_option]
                    if cross_compile:
                        options += ["-DCMAKE_SYSTEM_NAME=Darwin", "-DCMAKE_SYSTEM_PROCESSOR=" + args.architecture,
                                    "-DCMAKE_OSX_SYSROOT=" + args.sdk]
                    cmake_source = source
                    if args.cmake_project:
                        cmake_source = Path(args.cmake_project).resolve().parent
                        options += ["-DMVK_SOURCE=" + str(source), "-DMVK_GIT_REV=" + sources["main"][1]["revision"]]
                    run([cmake, "-S", cmake_source, "-B", work, "-G", "Ninja", *options], env=env, log=log)
                    run([cmake, "--build", work, "--target", args.target, "-j" + str(args.build_jobs)], env=env, log=log)
                    destination = prefix / args.artifact_name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(work / args.artifact, destination)
                else:
                    raise RuntimeError("Unsupported native build kind: " + args.kind)
            for file in prefix.rglob("*.la"):
                file.unlink()
            for file in prefix.rglob("*.pc"):
                text = file.read_text().replace(str(prefix), "${prefix}")
                text = re.sub(r"(?m)^prefix=.*$", "prefix=${pcfiledir}/../..", text)
                file.write_text(text)
            normalize_libraries(prefix, args.architecture, env)
            copy_licenses(source, output / "Licenses" / args.name)
            for name in sources:
                if name != "main":
                    copy_licenses(source / name, output / "Licenses" / Path(name).name)
    record = json.dumps(provenance, indent=2) + "\n"
    (output / "sources.json").write_text(record)
    notices = output / "Licenses" / args.name
    notices.mkdir(parents=True, exist_ok=True)
    (notices / "sources.json").write_text(record)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("name", "kind", "output", "sdk"):
        parser.add_argument("--" + name, required=True)
    for name in ("source", "dependency", "tool", "patch", "source-patch", "configure-option", "cmake-option"):
        parser.add_argument("--" + name, action="append", default=[])
    for name in ("target", "artifact", "artifact-name", "cmake-project", "cflags"):
        parser.add_argument("--" + name, default="")
    parser.add_argument("--strip-components", type=int, default=1)
    parser.add_argument("--architecture", choices=("arm64", "x86_64"), default="arm64")
    parser.add_argument("--build-jobs", type=int, default=4)
    args = parser.parse_args()
    if args.build_jobs < 1:
        parser.error("--build-jobs must be positive")
    build(args)
