# Wine

## Change the Build

| Change | Definition |
| --- | --- |
| Upstream revision and archive hash | [sources.lock.json](../sources.lock.json). |
| Dependencies, configure options and patch order | [BUILD.bazel](BUILD.bazel). |
| Launcher/runtime integration | [Runtime Architecture](../../docs/runtime.md#macos-integration). |

## Patch Scope

| Group | Architectures | Coverage |
| --- | --- | --- |
| `common_patches` | ARM64 and x86_64 | Window identity, Dock commands and attention, startup transitions, minimized surfaces, message queues and graphics integration. |
| `arm64_patches` | ARM64 | AnyCPU and ARM64X loading, unwinding, PE alignment, Darwin memory layout and register compatibility. |

Keep patches specific to individual behaviors and retain the order declared in `BUILD.bazel`. Common patches precede ARM64 patches.

## Compare Graphics Backends

| App target | Rendering |
| --- | --- |
| `//:MTGO` | DXVK and MoltenVK over Metal. |
| `//:MTGO_opengl` | WineD3D over OpenGL. |

Both targets use the same Wine build, allowing graphics comparisons with identical compatibility patches.
