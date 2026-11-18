load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "MoonGramNativeGifts",
    module_name = "MoonGramNativeGifts",
    srcs = glob(["Sources/**/*.swift"]),
    deps = [
        "//submodules/MoonGramCore",
        "//submodules/MoonGramUI",
        "//submodules/AccountContext",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/Gifts/GiftItemComponent",
    ],
    visibility = ["//visibility:public"],
)
