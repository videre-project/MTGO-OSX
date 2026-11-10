# Wine

Wine is built from the revision pinned in [`sources.lock.json`](../sources.lock.json), with dependencies and patch order declared in [`BUILD.bazel`](BUILD.bazel). ARM64 builds include AnyCPU, ARM64X and unwind fixes first used in mtgo-docker, together with macOS memory and register compatibility changes. Both architectures include window, Dock, taskbar-attention and graphics integration; see [Runtime Architecture](../../docs/runtime.md) for the corresponding launcher behavior.

The default Metal app and the `MTGO_opengl` comparison app use the same Wine build. Keep each patch specific to the behavior it changes so Wine upgrades can be reviewed separately from packaging changes.
