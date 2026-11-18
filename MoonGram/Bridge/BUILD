load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
swift_library(
    name = "MoonGramBridge",
    module_name = "MoonGramBridge",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [
        "//submodules/MoonGramCore",
        "//submodules/MoonGramVault",
        "//submodules/AccountContext",
        "//submodules/TelegramCore",
        "//submodules/PhotoResources",
        "//submodules/SSignalKit/SwiftSignalKit",
    ],
    visibility = ["//visibility:public"],
)
