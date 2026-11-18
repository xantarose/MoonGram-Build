load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "MoonGramUI",
    module_name = "MoonGramUI",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [
        "//submodules/MoonGramCore",
        "//submodules/MoonGramVault",
        "//submodules/Display",
        "//submodules/AsyncDisplayKit",
    ],
    visibility = ["//visibility:public"],
)
