#!/usr/bin/env python3
"""Run one upstream native build for a declared Bazel dependency."""

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import zipfile

from copy_tree import copy_tree


def run(command, *, cwd=None, env=None, log=None):
    try:
        subprocess.run([str(arg) for arg in command], cwd=cwd, env=env,
                       stdout=log, stderr=subprocess.STDOUT if log else None, check=True)
    except subprocess.CalledProcessError:
        if log:
            log.flush()
            print("\n".join(Path(log.name).read_text(errors="replace").splitlines()[-60:]), flush=True)
        raise


def extract(archive, destination, strip=1):
    destination.mkdir(parents=True, exist_ok=True)
    run(["/usr/bin/tar", "-xf", archive, "-C", destination, "--strip-components=" + str(strip)])


def copy_licenses(source, destination):
    for file in source.iterdir():
        if file.name.lower().startswith(("license", "copying", "copyright", "notice")):
            destination.mkdir(parents=True, exist_ok=True)
            copy_tree(file, destination / file.name, writable=True)


def normalize_libraries(prefix, architecture):
    """Keep native install names and loader paths independent of build directories."""
    library_dir = prefix / "lib"
    for file in prefix.rglob("*"):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open("rb") as stream:
            if stream.read(4) not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
                continue
        changes = []
        linked = subprocess.check_output(["/usr/bin/otool", "-L", file], text=True)
        for line in linked.splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                changes += ["-change", dependency, "@rpath/" + Path(dependency).name]
        if file.parent == library_dir and file.suffix == ".dylib":
            changes += ["-id", "@rpath/" + file.name]
        commands = subprocess.check_output(["/usr/bin/otool", "-l", file], text=True)
        for path in re.findall(r"\n\s+path (.+) \(offset \d+\)", commands):
            if path.startswith("/") and not path.startswith(("/usr/lib", "/System/Library")):
                changes += ["-delete_rpath", path]
        relative = os.path.relpath(library_dir, file.parent)
        rpath = "@loader_path" + ("/" + relative if relative != "." else "")
        if "path " + rpath + " (offset " not in commands:
            changes += ["-add_rpath", rpath]
        if changes:
            run(["/usr/bin/install_name_tool", *changes, file])
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", file])
        run(["/usr/bin/lipo", file, "-verify_arch", architecture])


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
    if platform.system() != "Darwin" or platform.machine() != args.architecture:
        raise RuntimeError("Run the native builder for its requested macOS architecture: " + args.architecture)
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
                compiler = subprocess.check_output(["/usr/bin/xcrun", "--find", "clang"], text=True).strip()
                env = dict(os.environ, LC_ALL="C", LANG="C", MACOSX_DEPLOYMENT_TARGET="13.0", SDKROOT=args.sdk)
                env["PATH"] = ":".join([str(tool / "bin") for tool in tools.values()] + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
                env["CC"] = compiler
                env["CXX"] = subprocess.check_output(["/usr/bin/xcrun", "--find", "clang++"], text=True).strip()
                env["CFLAGS"] = "-O2 -g -arch " + args.architecture + " -mmacosx-version-min=13.0" + (" " + args.cflags if args.cflags else "")
                env["CXXFLAGS"] = "-O2 -g -arch " + args.architecture + " -mmacosx-version-min=13.0"
                env["CPPFLAGS"] = "-I" + str(dependencies / "include")
                env["LDFLAGS"] = "-L" + str(dependencies / "lib") + " -Wl,-rpath," + str(dependencies / "lib")
                env["PKG_CONFIG_PATH"] = str(dependencies / "lib/pkgconfig")
                if "pkgconf" in tools:
                    env["PKG_CONFIG"] = str(tools["pkgconf"] / "bin/pkgconf")
                if "build_tools" in tools:
                    env["PYTHONPATH"] = str(tools["build_tools"] / "meson")
                work = root / "build"
                work.mkdir()
                if args.kind in ("autotools", "wine"):
                    configure = [source / "configure", *args.configure_option]
                    if args.kind == "wine":
                        configure += ["--prefix=/Runtime", "--libdir=/Runtime/lib"]
                    else:
                        configure += ["--prefix=" + str(prefix)]
                    run(configure, cwd=work, env=env, log=log)
                    run(["make", "-j4"], cwd=work, env=env, log=log)
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
                    cmake_source = source
                    if args.cmake_project:
                        cmake_source = Path(args.cmake_project).resolve().parent
                        options += ["-DMVK_SOURCE=" + str(source), "-DMVK_GIT_REV=" + sources["main"][1]["revision"]]
                    run([cmake, "-S", cmake_source, "-B", work, "-G", "Ninja", *options], env=env, log=log)
                    run([cmake, "--build", work, "--target", args.target, "-j4"], env=env, log=log)
                    destination = prefix / args.artifact_name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(work / args.artifact, destination)
                elif args.kind == "meson":
                    # Host compiler flags do not apply to the Windows cross compiler.
                    for name in ("CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS"):
                        env.pop(name, None)
                    run(["/usr/bin/python3", "-m", "mesonbuild.mesonmain", "setup", work, source,
                         "--cross-file", source / args.cross_file, "--buildtype", "release", "--wrap-mode", "nodownload", *args.meson_option], env=env, log=log)
                    run([tools["build_tools"] / "bin/ninja", "-C", work, "-j4"], env=env, log=log)
                    destination = prefix / args.artifact_name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(work / args.artifact, destination)
                    if args.cross_file == "build-arm64x.txt":
                        run(["/usr/bin/python3", source / "tools/ci/check-arm64x.py", destination], log=log)
                else:
                    raise RuntimeError("Unsupported native build kind: " + args.kind)
            for file in prefix.rglob("*.la"):
                file.unlink()
            for file in prefix.rglob("*.pc"):
                text = file.read_text().replace(str(prefix), "${prefix}")
                text = re.sub(r"(?m)^prefix=.*$", "prefix=${pcfiledir}/../..", text)
                file.write_text(text)
            normalize_libraries(prefix, args.architecture)
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
    for name in ("source", "dependency", "tool", "patch", "source-patch", "configure-option", "cmake-option", "meson-option"):
        parser.add_argument("--" + name, action="append", default=[])
    for name in ("target", "artifact", "artifact-name", "cmake-project", "cross-file", "cflags"):
        parser.add_argument("--" + name, default="")
    parser.add_argument("--strip-components", type=int, default=1)
    parser.add_argument("--architecture", choices=("arm64", "x86_64"), default="arm64")
    build(parser.parse_args())
