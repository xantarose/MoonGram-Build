#!/usr/bin/env python3
"""Launch the full personal client on a disposable simulator, without account login."""
import argparse
import json
from pathlib import Path, PurePosixPath
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False, check=True):
    return subprocess.run(args, check=check, capture_output=capture, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="moongram-full-smoke-") as temporary:
        stage = Path(temporary)
        with zipfile.ZipFile(args.ipa) as archive:
            if sum(entry.file_size for entry in archive.infolist()) > 4_294_967_296:
                raise RuntimeError("Oversized simulator archive.")
            for entry in archive.infolist():
                path = PurePosixPath(entry.filename)
                if path.is_absolute() or ".." in path.parts or stat.S_ISLNK(entry.external_attr >> 16):
                    raise RuntimeError("Unsafe simulator archive entry.")
                destination = stage.joinpath(*path.parts)
                if entry.is_dir():
                    destination.mkdir(parents=True, exist_ok=True)
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(entry) as source, destination.open("wb") as target:
                        shutil.copyfileobj(source, target)
                    destination.chmod((entry.external_attr >> 16) & 0o777 or 0o644)
        devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j", capture=True).stdout)
        choices = [(runtime, device) for runtime, items in devices["devices"].items() if ".iOS-" in runtime
                   for device in items if device.get("isAvailable") and "iPhone" in device["name"]]
        if not choices: raise RuntimeError("No available iPhone simulator runtime.")
        runtime, model = next(((r, d) for r, d in choices if "iPhone 17" in d["name"]), choices[0])
        device_type = model.get("deviceTypeIdentifier")
        if device_type is None:
            types = json.loads(run("xcrun", "simctl", "list", "devicetypes", "-j", capture=True).stdout)
            device_type = next(t["identifier"] for t in types["devicetypes"] if t["name"] == model["name"])
        udid = run("xcrun", "simctl", "create", "MoonGram full smoke", device_type, runtime, capture=True).stdout.strip()
        recorder = None
        output = ROOT / "dist/full-smoke"
        output.mkdir(parents=True, exist_ok=True)
        try:
            run("xcrun", "simctl", "boot", udid)
            run("xcrun", "simctl", "bootstatus", udid, "-b")
            run("xcrun", "simctl", "install", udid, str(stage / "Payload/Telegram.app"))
            with (stage / "recording.log").open("w") as log:
                recorder = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force", str(stage / "launch.mp4")], stdout=log, stderr=log)
                deadline = time.monotonic() + 15
                while "Recording started" not in (stage / "recording.log").read_text():
                    if recorder.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Simulator recording did not start.")
                    time.sleep(0.1)
                run("xcrun", "simctl", "launch", udid, "app.moongram.ios.personal")
                time.sleep(5)
                run("xcrun", "simctl", "io", udid, "screenshot", str(output / "full-client-welcome.png"))
                recorder.send_signal(signal.SIGINT)
                recorder.wait(timeout=20)
            shutil.copyfile(stage / "launch.mp4", output / "full-client-launch.mp4")
            (output / "scope.json").write_text(json.dumps({"device": model["name"], "runtime": runtime,
                "scope": "Full Telegram + MoonGram personal client, fresh simulator, no account login; inspect images before asserting visual success."}, indent=2))
        finally:
            if recorder is not None and recorder.poll() is None:
                recorder.send_signal(signal.SIGINT)
                try: recorder.wait(timeout=10)
                except subprocess.TimeoutExpired: recorder.kill(); recorder.wait()
            run("xcrun", "simctl", "shutdown", udid, check=False)
            run("xcrun", "simctl", "delete", udid, check=False)


if __name__ == "__main__":
    main()
