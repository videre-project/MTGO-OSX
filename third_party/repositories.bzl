"""Verified third-party archives and per-source provenance."""

def _source_impl(ctx):
    ctx.download(ctx.attr.url, "source.archive", sha256 = ctx.attr.sha256)
    metadata = {"url": ctx.attr.url, "sha256": ctx.attr.sha256}
    if ctx.attr.revision:
        metadata["revision"] = ctx.attr.revision
    ctx.file("source.json", json.encode_indent(metadata) + "\n")
    ctx.file("BUILD.bazel", 'filegroup(name = "source", srcs = ["source.archive", "source.json"], visibility = ["//visibility:public"])\n')

pinned_source = repository_rule(
    implementation = _source_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "revision": attr.string(),
    },
)

def _sources_impl(ctx):
    sources = json.decode(ctx.read(ctx.path(Label("//third_party:sources.lock.json"))))
    for name, source in sources.items():
        pinned_source(
            name = "mtgo_" + name,
            url = source["url"],
            sha256 = source["sha256"],
            revision = source.get("revision", ""),
        )

sources = module_extension(implementation = _sources_impl)
