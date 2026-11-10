# MoltenVK

MoltenVK is built with pinned SPIRV-Cross, Vulkan-Headers and cereal sources, plus Metal translation patches declared in [`BUILD.bazel`](BUILD.bazel). A [CMake wrapper](CMakeLists.txt) passes these source directories into the build, preventing additional dependency downloads during CMake configuration.

[SDK compatibility changes](patches/moltenvk-sdk14.patch) conditionally compile newer Metal and MetalFX declarations when the installed SDK provides them, and supply revision metadata for source-archive builds. Public Metal APIs are enabled with a macOS 13 deployment target. SDK availability checks permit compilation with older developer tools; they do not establish compatibility with every older macOS release.
