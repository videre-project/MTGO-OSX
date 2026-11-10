# Supply macos_sdk and compiler_rt as named build contexts from Apple developer tools.
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

ARG BUILD_JOBS=2

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    autoconf automake bison build-essential ca-certificates clang-18 cmake cpio curl file flex \
    gettext git libbz2-dev liblzma-dev libssl-dev libtool libxml2-dev llvm-18 llvm-18-dev \
    ninja-build patch pkg-config python3 texinfo unzip uuid-dev xz-utils zlib1g-dev zstd \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/opt/osxcross/target/bin:/usr/lib/llvm-18/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN mkdir -p /opt/osxcross && \
    curl --fail --location --retry 3 \
      https://codeload.github.com/tpoechtrager/osxcross/tar.gz/00bbf6b090a1f5fd8710adfe5d7da56da8282f96 \
      -o /tmp/osxcross.tar.gz && \
    echo '62af372424bb45381f685328e9c171814e574e51f141365920a66dd2e54a07aa  /tmp/osxcross.tar.gz' | sha256sum -c - && \
    tar -xf /tmp/osxcross.tar.gz -C /opt/osxcross --strip-components=1 && rm /tmp/osxcross.tar.gz

COPY --from=macos_sdk / /tmp/MacOSX.sdk

# ld64 supports the short-branch relocations used by GMP's optimized Intel assembly.
RUN set -eu; \
    sdk_version=$(python3 -c 'import json; print(json.load(open("/tmp/MacOSX.sdk/SDKSettings.json"))["Version"])'); \
    mv /tmp/MacOSX.sdk "/tmp/MacOSX$sdk_version.sdk"; \
    cd /opt/osxcross; \
    tar -czf "tarballs/MacOSX$sdk_version.sdk.tar.gz" -C /tmp "MacOSX$sdk_version.sdk"; \
    UNATTENDED=1 BUILD_FLAVOR=latest ENABLE_ARCHS='arm64 x86_64' OSX_VERSION_MIN=13.0 JOBS="$BUILD_JOBS" ./build.sh; \
    rm -rf "/tmp/MacOSX$sdk_version.sdk" tarballs/*.sdk.tar.gz build

# Darwin availability checks require a target compiler runtime when linking on Linux.
COPY --from=compiler_rt /libclang_rt.osx.a /usr/lib/llvm-18/lib/clang/18/lib/darwin/libclang_rt.osx.a

# Wine's Linux font converter needs host FreeType as well as the target macOS library.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libfreetype-dev \
    && rm -rf /var/lib/apt/lists/*

ENV OSXCROSS_ROOT=/opt/osxcross/target
ENV XDG_CACHE_HOME=/build/cache
WORKDIR /workspace
