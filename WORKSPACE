workspace(name = "rules_haskell")

load("//haskell:private/ghc_ci.bzl", "ghc_version")

ghc_version(name = "rules_haskell_ghc_version")

load("@rules_haskell//haskell:private/versions.bzl", "is_at_least")
load("//haskell:repositories.bzl", "rules_haskell_dependencies")

rules_haskell_dependencies()

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "io_bazel_stardoc",
    sha256 = "3fd8fec4ddec3c670bd810904e2e33170bedfe12f90adf943508184be458c8bb",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/stardoc/releases/download/0.5.3/stardoc-0.5.3.tar.gz",
        "https://github.com/bazelbuild/stardoc/releases/download/0.5.3/stardoc-0.5.3.tar.gz",
    ],
)

load("@aspect_rules_js//js:repositories.bzl", "rules_js_dependencies")

rules_js_dependencies()

load("@bazel_skylib//:workspace.bzl", "bazel_skylib_workspace")

bazel_skylib_workspace()

http_archive(
    name = "rules_proto",
    sha256 = "c6d6f9bfd39b6417724fd4a504767aa1e8dbfe828d9d41ab4ccd1976aba53fb4",
    strip_prefix = "rules_proto-7188888362a203892dec354f52623f9970bff48c",
    urls = ["https://github.com/bazelbuild/rules_proto/archive/7188888362a203892dec354f52623f9970bff48c.tar.gz"],
)

load("@rules_proto//proto:repositories.bzl", "rules_proto_dependencies", "rules_proto_toolchains")

rules_proto_dependencies()

rules_proto_toolchains()

# For buildifier
http_archive(
    name = "io_bazel_rules_go",
    sha256 = "80a98277ad1311dacd837f9b16db62887702e9f1d1c4c9f796d0121a46c8e184",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/rules_go/releases/download/v0.46.0/rules_go-v0.46.0.zip",
        "https://github.com/bazelbuild/rules_go/releases/download/v0.46.0/rules_go-v0.46.0.zip",
    ],
)

load("//:non_module_dev_deps.bzl", "repositories")

repositories(bzlmod = False)

load("//extensions:rules_haskell_dependencies.bzl", _repositories_3 = "repositories")

_repositories_3(bzlmod = False)

load("@rules_haskell_ghc_version//:ghc_version.bzl", "GHC_VERSION")
load(
    "@rules_haskell//haskell:ghc_bindist.bzl",
    "haskell_register_ghc_bindists",
)

haskell_register_ghc_bindists(version = GHC_VERSION)

load(
    "@rules_haskell//haskell/asterius:repositories.bzl",
    "asterius_dependencies_bindist",
    "asterius_dependencies_nix",
)
load(
    "@rules_nixpkgs_core//:nixpkgs.bzl",
    "nixpkgs_package",
)
load("@os_info//:os_info.bzl", "is_nix_shell", "is_windows")

asterius_dependencies_nix(
    nix_repository = "@nixpkgs_default",
    nixpkgs_package_rule = nixpkgs_package,
) if is_nix_shell else asterius_dependencies_bindist()

load("@rules_haskell_npm//:repositories.bzl", "npm_repositories")

npm_repositories()

register_toolchains(
    "//tests:protobuf-toolchain",
    "//tests:protobuf-toolchain-osx_arm64",
)

load("@io_bazel_stardoc//:setup.bzl", "stardoc_repositories")

stardoc_repositories()

register_toolchains(
    "@rules_haskell//docs/pandoc:nixpkgs",
    "@rules_haskell//docs/pandoc:linux",
    "@rules_haskell//docs/pandoc:macos",
)

# A repository that generates the Go SDK imports, see ./tools/go_sdk/README
local_repository(
    name = "go_sdk_repo",
    path = "tools/go_sdk",
)

load(
    "@io_bazel_rules_go//go:deps.bzl",
    "go_register_toolchains",
    "go_rules_dependencies",
)

go_rules_dependencies()

go_register_toolchains(version = "1.20.2")

load("@com_github_bazelbuild_buildtools//buildifier:deps.bzl", "buildifier_dependencies")

buildifier_dependencies()

http_archive(
    name = "cgrindel_bazel_starlib",
    sha256 = "00b084e895146d2dc8c76437dd5f91a7203c7b46bb4edd1896d018b8795bc927",
    urls = [
        "https://github.com/cgrindel/bazel-starlib/releases/download/v0.20.2/bazel-starlib.v0.20.2.tar.gz",
    ],
)

load("@cgrindel_bazel_starlib//:deps.bzl", "bazel_starlib_dependencies")

bazel_starlib_dependencies()

# For profiling
# Required to make use of `bazel build --profile`.
# Dummy target //external:python_headers.
# See https://github.com/protocolbuffers/protobuf/blob/d9ccd0c0e6bbda9bf4476088eeb46b02d7dcd327/util/python/BUILD
bind(
    name = "python_headers",
    actual = "@com_google_protobuf//util/python:python_headers",
)

load("@rules_haskell//haskell:cabal.bzl", "stack_snapshot")

# Needed for //tests:protobuf-toolchain which is required by //rule_info:rule_info_haskell_proto.
# rules_info_haskell_proto was not moved to rules_haskell_tests because it is in particular used by https://github.com/google/hrepl.
stack_snapshot(
    name = "stackage",
    components = {
        "c2hs": ["exe"],
        "proto-lens-protoc": [
            "lib",
            "exe",
        ],
    },
    local_snapshot = "//:stackage_snapshot{}.yaml".format(
        "_" + str(GHC_VERSION) if GHC_VERSION else "",
    ),
    packages = [
        "Cabal",
        # Core libraries
        "base",
        "bytestring",
        "containers",
        "deepseq",
        "mtl",
        "text",
        "vector",
        # For tests
        "alex",
        "c2hs",
        "happy",
        "lens-family-core",
        "data-default-class",
        "proto-lens",
        "proto-lens-protoc",
        "proto-lens-runtime",
        "lens-family",
    ],
    setup_deps = {} if GHC_VERSION and is_at_least("9.6", GHC_VERSION) else {
        # See https://github.com/tweag/rules_haskell/issues/1871
        "HUnit": ["@Cabal//:Cabal"],
        "bifunctors": ["@Cabal//:Cabal"],
        "call-stack": ["@Cabal//:Cabal"],
        "generic-deriving": ["@Cabal//:Cabal"],
        "mono-traversable": ["@Cabal//:Cabal"],
        "proto-lens-protoc": ["@Cabal//:Cabal"],
        "proto-lens-runtime": ["@Cabal//:Cabal"],
        "quickcheck-io": ["@Cabal//:Cabal"],
        "transformers-compat": ["@Cabal//:Cabal"],
        "type-errors": ["@Cabal//:Cabal"],
        "typed-process": ["@Cabal//:Cabal"],
        "unliftio-core": ["@Cabal//:Cabal"],
        "alex": ["@Cabal//:Cabal"],
        "c2hs": ["@Cabal//:Cabal"],
        "happy": ["@Cabal//:Cabal"],
    },
    stack_snapshot_json = "//:stackage_snapshot{}.json".format(
        "_" + str(GHC_VERSION) if GHC_VERSION else "",
    ) if not is_windows else None,
    vendored_packages = {
        "ghc-paths": "@rules_haskell//tools/ghc-paths",
    },
)
