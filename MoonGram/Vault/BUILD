load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
swift_library(
    name = "MoonGramVault",
    module_name = "MoonGramVault",
    srcs = glob(["Sources/**/*.swift"]),
    deps = ["//submodules/MoonGramCore"],
    visibility = ["//visibility:public"],
)
