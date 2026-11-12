# MoltenVK

## Change the Build

| Change | Definition |
| --- | --- |
| MoltenVK, SPIRV-Cross, Vulkan-Headers and cereal pins | [sources.lock.json](../sources.lock.json). |
| Source directories and Metal translation patches | [BUILD.bazel](BUILD.bazel). |
| CMake options and dependency wiring | [CMakeLists.txt](CMakeLists.txt). |
| SDK compatibility | [moltenvk-sdk14.patch](patches/moltenvk-sdk14.patch). |

Pass verified source directories through the CMake wrapper. Configuration uses these local dependencies without additional downloads.

## SDK Requirements

| Setting | Behavior |
| --- | --- |
| Deployment target | macOS 13. |
| Metal API | Public APIs; `MVK_USE_METAL_PRIVATE_API=OFF`. |
| Newer Metal and MetalFX declarations | Compile conditionally when available in the installed SDK. |
| Source-archive revision metadata | Supplied by the compatibility patch. |

SDK checks permit compilation with older developer tools. Runtime compatibility still requires validation on the target macOS release; see [macOS Compatibility](../../docs/runtime.md#macos-compatibility).
