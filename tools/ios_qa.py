#!/usr/bin/env python3
"""Generate and build an isolated native iOS QA app for our UI, without Telegram credentials."""
import hashlib
import json
from pathlib import Path
import platform
import signal
import tempfile
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".build/ios-qa"


def identity(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(str(value))


def generate():
    objects = {}

    def obj(name, isa, fields):
        key = identity(name)
        objects[key] = "{isa = " + isa + "; " + fields + "}"
        return key

    def array(values):
        return "(" + ",".join(values) + ")"

    def configurations(name, settings):
        refs = []
        for config in ["Debug", "Release"]:
            common = {"SWIFT_VERSION": "5.0", "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
                      "CLANG_ENABLE_MODULES": "YES", "CODE_SIGNING_ALLOWED": "NO", "TARGETED_DEVICE_FAMILY": "1,2",
                      "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O", **settings}
            content = " ".join(quote(k) + " = " + quote(v) + ";" for k, v in common.items())
            refs.append(obj(name + config, "XCBuildConfiguration", f"buildSettings = {{{content}}}; name = {config};"))
        return obj(name + "configs", "XCConfigurationList", f"buildConfigurations = {array(refs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;")

    project_id = identity("project")
    products, targets, file_refs = [], [], []
    product_refs, target_ids = {}, {}
    modules = [
        ("MoonGramCore", sorted((ROOT / "MoonGram/Core/Sources").glob("*.swift")), []),
        ("MoonGramVault", sorted((ROOT / "MoonGram/Vault/Sources").glob("*.swift")), ["MoonGramCore"]),
        ("MoonGramUI", sorted((ROOT / "MoonGram/UI/Sources").glob("*.swift")), ["MoonGramCore", "MoonGramVault"]),
        ("MoonGramQA", [ROOT / "Checks/MoonGramQAApp.swift"], ["MoonGramCore", "MoonGramVault", "MoonGramUI"]),
    ]
    for name, files, dependencies in modules:
        app = name == "MoonGramQA"
        product_refs[name] = obj(name + "product", "PBXFileReference", f"explicitFileType = {quote('wrapper.application' if app else 'wrapper.framework')}; path = {quote(name + ('.app' if app else '.framework'))}; sourceTree = BUILT_PRODUCTS_DIR;")
        products.append(product_refs[name])
        source_refs = []
        for file in files:
            relative = file.relative_to(ROOT).as_posix()
            reference = obj(relative, "PBXFileReference", f"lastKnownFileType = sourcecode.swift; path = {quote('../../' + relative)}; sourceTree = SOURCE_ROOT;")
            file_refs.append(reference)
            source_refs.append(obj(relative + "build", "PBXBuildFile", f"fileRef = {reference};"))
        phases = [obj(name + "sources", "PBXSourcesBuildPhase", f"buildActionMask = 2147483647; files = {array(source_refs)}; runOnlyForDeploymentPostprocessing = 0;")]
        linked, dependency_refs, embedded = [], [], []
        for dependency in dependencies:
            linked.append(obj(name + dependency + "link", "PBXBuildFile", f"fileRef = {product_refs[dependency]};"))
            proxy = obj(name + dependency + "proxy", "PBXContainerItemProxy", f"containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {target_ids[dependency]}; remoteInfo = {quote(dependency)};")
            dependency_refs.append(obj(name + dependency + "dep", "PBXTargetDependency", f"target = {target_ids[dependency]}; targetProxy = {proxy};"))
            if app:
                embedded.append(obj(name + dependency + "embed", "PBXBuildFile", f"fileRef = {product_refs[dependency]}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy);}};"))
        phases.append(obj(name + "frameworks", "PBXFrameworksBuildPhase", f"buildActionMask = 2147483647; files = {array(linked)}; runOnlyForDeploymentPostprocessing = 0;"))
        if app:
            phases.append(obj(name + "embedphase", "PBXCopyFilesBuildPhase", f"buildActionMask = 2147483647; dstPath = {quote('')}; dstSubfolderSpec = 10; files = {array(embedded)}; name = {quote('Embed Frameworks')}; runOnlyForDeploymentPostprocessing = 0;"))
        settings = {"PRODUCT_BUNDLE_IDENTIFIER": "app.moongram.qa." + name.lower(), "PRODUCT_NAME": name,
                    "DEFINES_MODULE": "YES", "GENERATE_INFOPLIST_FILE": "YES", "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES"}
        if app:
            settings.update({"LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks", "INFOPLIST_KEY_CFBundleDisplayName": "MoonGram QA",
                             "INFOPLIST_KEY_UILaunchScreen_Generation": "YES", "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES"})
        else:
            settings.update({"SKIP_INSTALL": "YES", "DYLIB_INSTALL_NAME_BASE": "@rpath", "INSTALL_PATH": "$(LOCAL_LIBRARY_DIR)/Frameworks"})
        configs = configurations(name, settings)
        target = obj(name + "target", "PBXNativeTarget", f"buildConfigurationList = {configs}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array(dependency_refs)}; name = {quote(name)}; productName = {quote(name)}; productReference = {product_refs[name]}; productType = {quote('com.apple.product-type.application' if app else 'com.apple.product-type.framework')};")
        target_ids[name] = target
        targets.append(target)
    products_group = obj("products", "PBXGroup", f"children = {array(products)}; name = Products; sourceTree = {quote('<group>')};")
    main_group = obj("main", "PBXGroup", f"children = {array(file_refs + [products_group])}; sourceTree = {quote('<group>')};")
    project_configs = configurations("project", {})
    obj("project", "PBXProject", f"attributes = {{LastUpgradeCheck = 2710;}}; buildConfigurationList = {project_configs}; compatibilityVersion = {quote('Xcode 15.0')}; developmentRegion = en; knownRegions = (en,Base); mainGroup = {main_group}; productRefGroup = {products_group}; projectDirPath = {quote('')}; projectRoot = {quote('')}; targets = {array(targets)};")
    project = OUT / "MoonGramQA.xcodeproj"
    project.mkdir(parents=True, exist_ok=True)
    text = "// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n"
    text += "\n".join(key + " = " + value + ";" for key, value in objects.items())
    text += "\n}; rootObject = " + project_id + ";}\n"
    (project / "project.pbxproj").write_text(text)
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    (schemes / "MoonGramQA.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids['MoonGramQA']}" BuildableName="MoonGramQA.app" BlueprintName="MoonGramQA" ReferencedContainer="container:MoonGramQA.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"/></Scheme>''')
    return project


def run(*args, capture=False, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=capture)


def screenshots(app):
    simulator = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j", capture=True).stdout)
    choices = [(runtime, device) for runtime, devices in simulator["devices"].items() if ".iOS-" in runtime
               for device in devices if device.get("isAvailable") and "iPhone" in device["name"]]
    if not choices:
        raise RuntimeError("No available iPhone simulator runtime; screenshots not performed.")
    runtime, device = next(((r, d) for r, d in choices if "iPhone 17" in d["name"]), choices[0])
    udid = device["udid"]
    created = device["state"] != "Booted"
    output = ROOT / "dist/ios-qa"
    output.mkdir(parents=True, exist_ok=True)
    try:
        if created: run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b")
        run("xcrun", "simctl", "install", udid, str(app))
        for appearance in ["light", "dark"]:
            run("xcrun", "simctl", "ui", udid, "appearance", appearance)
            for screen, arguments in [
                ("settings", []), ("profile-editor", ["--profile-editor"]),
                ("gift-editor", ["--gift-editor"]), ("gift-keyboard", ["--gift-editor", "--open-keyboard"]),
                ("compact-editor", ["--compact-editor"]), ("privacy", ["--privacy"]),
            ]:
                run("xcrun", "simctl", "terminate", udid, "app.moongram.qa.moongramqa", check=False)
                with tempfile.TemporaryDirectory(prefix="moongram-qa-recording-") as temporary:
                    recording = None
                    with (Path(temporary) / "record.log").open("w+") as record_log:
                        try:
                            if screen == "privacy":
                                recording = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force",
                                                              str(output / f"privacy-{appearance}.mp4")], stdout=record_log, stderr=subprocess.STDOUT)
                                deadline = time.monotonic() + 10
                                while time.monotonic() < deadline:
                                    record_log.seek(0)
                                    if "Recording started" in record_log.read(): break
                                    if recording.poll() is not None: raise RuntimeError("Privacy recording failed before launch.")
                                    time.sleep(0.1)
                                else: raise RuntimeError("Privacy recording did not start in time.")
                            run("xcrun", "simctl", "launch", udid, "app.moongram.qa.moongramqa", *arguments)
                            time.sleep(2)
                            run("xcrun", "simctl", "io", udid, "screenshot", str(output / f"{screen}-{appearance}.png"))
                        finally:
                            if recording is not None:
                                if recording.poll() is None: recording.send_signal(signal.SIGINT)
                                recording.wait(timeout=15)
        (output / "device.json").write_text(json.dumps({"runtime": runtime, "device": device["name"], "scope": "MoonGram UI QA app; not full Telegram"}, indent=2))
    finally:
        if created: run("xcrun", "simctl", "shutdown", udid, check=False)


def main():
    project = generate()
    if sys.argv[1:] == ["--generate-only"]:
        print(project)
        return 0
    if platform.system() != "Darwin":
        raise SystemExit("Native UI verification requires Xcode on macOS.")
    run("xcodebuild", "-project", str(project), "-scheme", "MoonGramQA", "-configuration", "Debug",
        "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(OUT / "DerivedData"), "CODE_SIGNING_ALLOWED=NO", "build")
    screenshots(OUT / "DerivedData/Build/Products/Debug-iphonesimulator/MoonGramQA.app")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
