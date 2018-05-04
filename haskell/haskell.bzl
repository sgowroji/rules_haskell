"""Core Haskell rules"""

load(":providers.bzl",
  "HaskellBuildInfo",
  "HaskellLibraryInfo",
  "HaskellBinaryInfo",
  "HaskellProtobufInfo",
  "CcSkylarkApiProviderHacked",
)

load(":actions.bzl",
  "compile_haskell_bin",
  "link_haskell_bin",
  "compile_haskell_lib",
  "link_static_lib",
  "link_dynamic_lib",
  "create_ghc_package",
  "gather_dep_info",
  "get_pkg_id",
)

load(":set.bzl", "set")
load("@bazel_skylib//:lib.bzl", "paths")

load(":path_utils.bzl",
     "import_hierarchy_root",
)
load(":ghci-repl.bzl",
  _build_haskell_repl = "build_haskell_repl",
)

# For re-exports:
load(":protobuf.bzl",
  _haskell_proto_aspect = "haskell_proto_aspect",
  _haskell_proto_toolchain = "haskell_proto_toolchain",
)
load(":haddock.bzl",
  _haskell_doc = "haskell_doc",
)
load(":lint.bzl",
  _haskell_lint = "haskell_lint",
  _haskell_doctest = "haskell_doctest",
)
load(":toolchain.bzl",
  _haskell_toolchain = "haskell_toolchain",
)
load (":ghc_bindist.bzl",
  _ghc_bindist = "ghc_bindist",
)
load(":cc.bzl",
  _haskell_cc_import = "haskell_cc_import",
  _cc_haskell_import = "cc_haskell_import",
)

_haskell_common_attrs = {
  "src_strip_prefix": attr.string(
    doc = "Directory in which module hierarchy starts.",
  ),
  "srcs": attr.label_list(
    allow_files = FileType([".hs", ".hsc", ".lhs", ".hs-boot", ".lhs-boot", ".h"]),
    doc = "Haskell source files.",
  ),
  "deps": attr.label_list(
    doc = "List of other Haskell libraries to be linked to this target.",
  ),
  "data": attr.label_list(
    doc = "See [Bazel documentation](https://docs.bazel.build/versions/master/be/common-definitions.html#common.data).",
    allow_files = True,
    cfg = "data",
  ),
  "compiler_flags": attr.string_list(
    doc = "Flags to pass to Haskell compiler.",
  ),
  "prebuilt_dependencies": attr.string_list(
    doc = "Non-Bazel supplied Cabal dependencies.",
  ),
  "repl_interpreted": attr.bool(
    default=True,
    doc = """
Whether source files should be interpreted rather than compiled. This allows
for e.g. reloading of sources on editing, but in this case we don't handle
boot files and hsc processing.

For `haskell_binary` targets, `repl_interpreted` must be set to `True` for
REPL to work.
"""),
  "repl_ghci_args": attr.string_list(
    doc = "Arbitrary extra arguments to pass to GHCi.",
  ),
  # XXX Consider making this private. Blocked on
  # https://github.com/bazelbuild/bazel/issues/4366.
  "version": attr.string(
    default = "1.0.0",
    doc = "Library/binary version. Internal - do not use."
  ),
  "_ghc_defs_cleanup": attr.label(
    allow_single_file = True,
    default = Label("@io_tweag_rules_haskell//haskell:ghc-defs-cleanup.sh"),
  ),
  "_ghci_script": attr.label(
    allow_single_file = True,
    default = Label("@io_tweag_rules_haskell//haskell:ghci-script"),
  ),
  "_ghci_repl_wrapper": attr.label(
    allow_single_file = True,
    default = Label("@io_tweag_rules_haskell//haskell:ghci-repl-wrapper.sh"),
  ),
}

def _haskell_binary_impl(ctx):
  c = compile_haskell_bin(ctx)

  binary = link_haskell_bin(ctx, c.object_dyn_files)
  dep_info = gather_dep_info(ctx)

  solibs = set.union(
    set.from_list(dep_info.external_libraries.values()),
    dep_info.dynamic_libraries,
  )

  build_info = dep_info # HaskellBuildInfo
  bin_info = HaskellBinaryInfo(
    source_files = c.source_files,
    modules = c.modules,
    binary = binary,
  )
  target_files = depset([binary])

  _build_haskell_repl(
    ctx,
    build_info=build_info,
    target_files=target_files,
    bin_info=bin_info,
  )

  return [
    build_info,
    bin_info,
    DefaultInfo(
      executable = binary,
      files = target_files,
      runfiles = ctx.runfiles(
        files = set.to_list(solibs),
        collect_data = True,
      ),
    ),
  ]

def _mk_binary_rule(**kwargs):
  """Generate a rule that compiles a binary.

  This is useful to create variations of a Haskell binary compilation
  rule without having to copy and paste the actual `rule` invocation.

  Args:
    **kwargs: Any additional keyword arguments to pass to `rule`.

  Returns:
    Rule: Haskell binary compilation rule.
  """
  return rule(
    _haskell_binary_impl,
    executable = True,
    attrs = dict(
      _haskell_common_attrs,
      generate_so = attr.bool(
        default = False,
        doc = "Whether to generate also a .so version of executable.",
      ),
      main_function = attr.string(
        default = "Main.main",
        doc = "Location of `main` function.",
      ),
      main_file = attr.label(
        allow_single_file = FileType([".hs", ".hsc", ".lhs"]),
        doc = "File containing `Main` module.",
      )
    ),
    outputs = {
      "repl": "%{name}-repl",
    },
    toolchains = ["@io_tweag_rules_haskell//haskell:toolchain"],
    **kwargs
  )

haskell_test = _mk_binary_rule(test = True)
"""Build a test suite.

Additionally, it accepts [all common bazel test rule
fields][bazel-test-attrs]. This allows you to influence things like
timeout and resource allocation for the test.

[bazel-test-attrs]: https://docs.bazel.build/versions/master/be/common-definitions.html#common-attributes-tests
"""

haskell_binary = _mk_binary_rule()
"""Build an executable from Haskell source.

Example:
  ```bzl
  haskell_binary(
      name = "main",
      srcs = ["Main.hs", "Other.hs"],
      deps = ["//lib:some_lib"]
  )
  ```

Every `haskell_binary` target also defines an optional REPL target that is
not built by default, but can be built on request. The name of the REPL
target is the same as the name of binary with `"-repl"` added at the end.
For example, the target above also defines `main-repl`.

You can call the REPL like this (requires Bazel 0.12 or later):

```
$ bazel run --direct_run //:hello-bin-repl
```

With older Bazel versions:

```
$ bazel build //:hello-bin-repl # build the script
$ bazel-bin/.../hello-bin-repl  # run the script
```
"""

def _haskell_library_impl(ctx, use_these_srcs=None):

  c = compile_haskell_lib(ctx, use_these_srcs = use_these_srcs)

  static_library = link_static_lib(ctx, c.object_files)
  dynamic_library = link_dynamic_lib(ctx, c.object_dyn_files)

  dep_info = gather_dep_info(ctx)

  exposed_modules = set.empty()
  other_modules = set.from_list(ctx.attr.hidden_modules)

  for module in set.to_list(c.modules):
    if not set.is_member(other_modules, module):
      set.mutable_insert(exposed_modules, module)

  conf_file, cache_file = create_ghc_package(
    ctx,
    c.interfaces_dir,
    static_library,
    dynamic_library,
    exposed_modules,
    other_modules,
  )

  build_info = HaskellBuildInfo(
    package_names = set.insert(dep_info.package_names, get_pkg_id(ctx)),
    package_confs = set.insert(dep_info.package_confs, conf_file),
    package_caches = set.insert(dep_info.package_caches, cache_file),
    # NOTE We have to use lists for static libraries because the order is
    # important for linker. Linker searches for unresolved symbols to the
    # left, i.e. you first feed a library which has unresolved symbols and
    # then you feed the library which resolves the symbols.
    static_libraries = [static_library] + dep_info.static_libraries,
    dynamic_libraries = set.insert(dep_info.dynamic_libraries, dynamic_library),
    interface_files = set.union(dep_info.interface_files, set.from_list(c.interface_files)),
    prebuilt_dependencies = dep_info.prebuilt_dependencies,
    external_libraries = dep_info.external_libraries,
  )
  lib_info = HaskellLibraryInfo(
    package_name = get_pkg_id(ctx),
    import_dirs = c.import_dirs,
    exposed_modules = exposed_modules,
    other_modules = other_modules,
    haddock_args = c.haddock_args,
    source_files = c.source_files,
  )
  target_files = depset([conf_file, cache_file])

  _build_haskell_repl(
    ctx,
    build_info=build_info,
    target_files=target_files,
    lib_info=lib_info,
  )

  return [
    build_info,
    lib_info,
    DefaultInfo(
      files = target_files,
      runfiles = ctx.runfiles(collect_data = True),
    ),
  ]

haskell_library = rule(
  _haskell_library_impl,
  attrs = dict(
    _haskell_common_attrs,
    hidden_modules = attr.string_list(
      doc = "Modules that should be unavailable for import by dependencies."
    )),
  outputs = {
    "repl": "%{name}-repl",
  },
  toolchains = ["@io_tweag_rules_haskell//haskell:toolchain"],
)
"""Build a library from Haskell source.

Example:
  ```bzl
  haskell_library(
      name = 'hello-lib',
      srcs = glob(['hello_lib/**/*.hs']),
      deps = ["//hello-sublib:lib"],
      prebuilt_dependencies = ["base", "bytestring"],
  )
  ```

Every `haskell_library` target also defines an optional REPL target that is
not built by default, but can be built on request. The name of the REPL
target is the same as the name of library with `"-repl"` added at the end.
For example, the target above also defines `hello-lib-repl`.

You can call the REPL like this (requires Bazel 0.12 or later):

```
$ bazel run --direct_run //:hello-lib-repl
```

With older Bazel versions:

```
$ bazel build //:hello-lib-repl # build the script
$ bazel-bin/.../hello-lib-repl  # run the script
```
"""

def _haskell_proto_library_impl(ctx):

  source_files = depset()
  for dep in ctx.attr.deps:
    if HaskellProtobufInfo in dep:
      source_files = depset(transitive = [
        source_files,
        dep[HaskellProtobufInfo].source_files,
      ])

  return _haskell_library_impl(
    ctx,
    use_these_srcs=source_files,
  )

haskell_proto_library = rule(
  _haskell_proto_library_impl,
  attrs = dict(
    _haskell_common_attrs,
    hidden_modules = attr.string_list(
      doc = "Modules that should be unavailable for import by dependencies."
    ),
    deps = attr.label_list(
      aspects = [_haskell_proto_aspect],
      doc = "List of `proto_library` targets to use for generation.",
    ),
  ),
  outputs = {
    "repl": "%{name}-repl",
  },
  toolchains = [
    "@io_tweag_rules_haskell//haskell:toolchain",
    "@io_tweag_rules_haskell//protobuf:toolchain",
  ]
)
"""Generate Haskell library allowing to use protobuf definitions with help
of [`proto-lens`](https://github.com/google/proto-lens#readme).

Example:
  ```bzl
  proto_library(
    name = "foo_proto",
    srcs = ["foo.proto"],
  )

  haskell_proto_library(
    name = "foo_haskell_proto",
    deps = [":foo_proto"],
  )
  ```

`haskell_proto_library` targets require `haskell_proto_toolchain` to be
registered.
"""

haskell_doc = _haskell_doc

haskell_lint = _haskell_lint

haskell_doctest  = _haskell_doctest

haskell_toolchain = _haskell_toolchain

haskell_proto_toolchain = _haskell_proto_toolchain

ghc_bindist = _ghc_bindist

haskell_cc_import = _haskell_cc_import

cc_haskell_import = _cc_haskell_import
