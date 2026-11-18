"""Verify the main executable's Apple platform, architecture and encryption state."""
import json
import plistlib
from build_configuration import from_api_credentials
import struct
import zipfile


def inspect_macho(header):
    if len(header) < 32 or header[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected a thin little-endian 64-bit Mach-O executable.")
    cpu, _, file_type, count, size = struct.unpack_from("<IIIII", header, 4)
    if cpu != 0x0100000C or file_type != 2:
        raise ValueError("Expected an ARM64 application executable.")
    end = 32 + size
    if end > len(header) or count > 4096:
        raise ValueError("Invalid or oversized Mach-O load commands.")
    offset = 32
    platform = None
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated Mach-O load command.")
        command, length = struct.unpack_from("<II", header, offset)
        if length < 8 or length % 4 or offset + length > end:
            raise ValueError("Invalid Mach-O load command size.")
        if command == 0x32:  # LC_BUILD_VERSION, Apple mach-o/loader.h
            if length < 24 or platform is not None:
                raise ValueError("Invalid or duplicate Mach-O build version.")
            platform = struct.unpack_from("<I", header, offset + 8)[0]
        elif command in (0x21, 0x2C):  # LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64
            if length < 20 or struct.unpack_from("<I", header, offset + 16)[0] != 0:
                raise ValueError("Encrypted application executable is not a build artifact.")
        offset += length
    if offset != end or platform is None:
        raise ValueError("Executable has no complete Apple platform metadata.")
    return {"architecture": "arm64", "platform": platform, "encrypted": False}


def verify_ipa(ipa, bundle_id, kind, allow_unconfigured=False):
    runtime_required = False
    configured = False
    with zipfile.ZipFile(ipa) as archive:
        info = plistlib.loads(archive.read("Payload/Telegram.app/Info.plist"))
        if info.get("CFBundleIdentifier") != bundle_id or info.get("CFBundleDisplayName") != "MoonGram":
            raise ValueError("The built IPA does not identify as the requested MoonGram application.")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or "/" in executable or "\\" in executable:
            raise ValueError("Invalid IPA executable name.")
        binary = "Payload/Telegram.app/" + executable
        if archive.getinfo(binary).file_size > 536_870_912:
            raise ValueError("Oversized application executable.")
        with archive.open(binary) as stream:
            report = inspect_macho(stream.read(1_048_576))
        expected = 7 if kind.endswith("simulator") else 2  # PLATFORM_IOSSIMULATOR / PLATFORM_IOS
        if report["platform"] != expected:
            raise ValueError("IPA executable targets the wrong Apple platform.")
        if kind.startswith("standalone-"):
            if info.get("MoonGramStorageMode") != "standalone" or not bundle_id.endswith(".personal"):
                raise ValueError("Personal IPA storage marker and bundle namespace do not match.")
            if any("/PlugIns/" in name or name.startswith("Payload/Telegram.app/Watch/") for name in archive.namelist()):
                raise ValueError("Personal IPA must contain no app extensions or Watch app.")
        runtime_required = info.get("MoonGramRuntimeAPIRequired") is True
        if runtime_required:
            if not kind.startswith("standalone-"): raise ValueError("Runtime API configuration requires personal storage.")
            resource = "Payload/Telegram.app/MoonGramAPI.json"
            if resource in archive.namelist():
                if archive.getinfo(resource).file_size > 4096: raise ValueError("Oversized runtime API configuration.")
                credentials = json.loads(archive.read(resource))
                if not isinstance(credentials, dict) or type(credentials.get("api_id")) is not int:
                    raise ValueError("Runtime API ID must be an integer.")
                from_api_credentials(credentials, kind)
                configured = True
            elif not allow_unconfigured:
                raise ValueError("Template requires local API configuration before signing and login.")
        if kind in ("unsigned-device", "standalone-device") and "Payload/Telegram.app/embedded.mobileprovision" in archive.namelist():
            raise ValueError("Unsigned build unexpectedly contains a provisioning profile.")
    return {**report, "runtime_api_required": runtime_required, "runtime_api_configured": configured, "bundle_id": bundle_id, "build_kind": kind, "requires_resigning": kind in ("unsigned-device", "standalone-device"), "storage_mode": "standalone" if kind.startswith("standalone-") else "app-group"}
