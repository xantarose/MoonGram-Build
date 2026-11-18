#!/usr/bin/env python3
"""Create a private build configuration without committing or logging credentials."""
import argparse
import json
import os
from pathlib import Path
import re
import tempfile

KINDS = ("simulator", "unsigned-device", "standalone-simulator", "standalone-device", "device")
DEFAULTS = {
    "bundle_id": "app.moongram.ios",
    "team_id": "",
    "is_internal_build": "true",
    "is_appstore_build": "false",
    "appstore_id": "0",
    "app_specific_url_scheme": "moongram",
    "premium_iap_product_id": "",
    "enable_siri": False,
    "enable_icloud": False,
}


def validate_configuration(config, kind):
    if kind not in KINDS or not isinstance(config, dict):
        raise ValueError("Invalid build configuration or build kind.")
    if set(config) != set(DEFAULTS) | {"api_id", "api_hash"}:
        raise ValueError("Build configuration must contain exactly the documented fields.")
    candidate = dict(config)
    api_id = candidate["api_id"]
    if isinstance(api_id, bool) or not re.fullmatch(r"[0-9]{1,10}", str(api_id)) or not 0 < int(api_id) < 2**31:
        raise ValueError("A positive Telegram api_id within Int32 range is required.")
    candidate["api_id"] = str(int(api_id))
    if not isinstance(candidate["api_hash"], str) or not re.fullmatch(r"[0-9a-fA-F]{32}", candidate["api_hash"]):
        raise ValueError("A 32-character Telegram api_hash is required; its value is omitted.")
    team = candidate["team_id"]
    if not isinstance(team, str) or not (re.fullmatch(r"[A-Z0-9]{10}", team) or (team == "" and kind != "device")):
        raise ValueError("Signed device builds require the real 10-character Apple Team ID.")
    bundle = candidate["bundle_id"]
    if not isinstance(bundle, str) or len(bundle) > 128 or not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+){2,}", bundle):
        raise ValueError("A valid independent bundle ID is required.")
    if kind.startswith("standalone-") != bundle.endswith(".personal"):
        raise ValueError("The personal bundle namespace is reserved for the standalone storage mode.")
    if kind.startswith("standalone-") and (candidate["enable_siri"] is not False or candidate["enable_icloud"] is not False):
        raise ValueError("Personal builds do not provide Siri or iCloud capabilities.")
    if bundle == "ph.telegra.Telegraph":
        raise ValueError("Use an independent bundle ID for MoonGram.")
    for key in ("is_internal_build", "is_appstore_build"):
        if candidate[key] not in ("true", "false"):
            raise ValueError("Build flags must be the strings true or false.")
    if not isinstance(candidate["appstore_id"], str) or not re.fullmatch(r"[0-9]{1,20}", candidate["appstore_id"]):
        raise ValueError("appstore_id must be a decimal string.")
    scheme = candidate["app_specific_url_scheme"]
    if not isinstance(scheme, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9+.-]{0,63}", scheme):
        raise ValueError("Invalid app URL scheme.")
    product = candidate["premium_iap_product_id"]
    if not isinstance(product, str) or not re.fullmatch(r"[A-Za-z0-9._-]{0,128}", product):
        raise ValueError("Invalid Premium product identifier.")
    for key in ("enable_siri", "enable_icloud"):
        if type(candidate[key]) is not bool:
            raise ValueError("Siri and iCloud settings must be JSON booleans.")
    return candidate


def from_api_credentials(credentials, kind):
    if not isinstance(credentials, dict) or set(credentials) != {"api_id", "api_hash"}:
        raise ValueError("Telegram API secret must contain only api_id and api_hash.")
    if kind == "device":
        raise ValueError("Signed device builds need MOONGRAM_BUILD_CONFIG with real signing identifiers.")
    # Empty team_id is deliberately unsigned metadata, never a fabricated signing identity.
    config = {**DEFAULTS, **credentials}
    if kind.startswith("standalone-"):
        config["bundle_id"] += ".personal"
        config["app_specific_url_scheme"] = "moongram-personal"
    return validate_configuration(config, kind)


def template_configuration(kind):
    if kind not in ("standalone-device", "standalone-simulator"):
        raise ValueError("Public templates require a personal build kind.")
    return from_api_credentials({"api_id": "1", "api_hash": "0" * 32}, kind)


def write_private(path, config):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("Refusing to replace a symbolic build configuration.")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".moongram-config-", delete=False) as stream:
            temporary = Path(stream.name)
            os.chmod(temporary, 0o600)
            json.dump(config, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=KINDS, required=True)
    parser.add_argument("--output", type=Path, default=Path("build.local.json"))
    parser.add_argument("--local-api", type=Path, help="Ignored local API JSON; never pass secrets as arguments.")
    parser.add_argument("--template", action="store_true", help="Use public placeholders, ignoring all credential environment variables.")
    args = parser.parse_args()
    try:
        if args.template:
            if args.local_api: raise ValueError("Templates cannot read a private API file.")
            config = template_configuration(args.kind)
        elif args.local_api:
            config = from_api_credentials(json.loads(args.local_api.read_text()), args.kind)
        elif os.environ.get("MOONGRAM_BUILD_CONFIG"):
            config = validate_configuration(json.loads(os.environ["MOONGRAM_BUILD_CONFIG"]), args.kind)
        elif os.environ.get("MOONGRAM_TELEGRAM_API"):
            config = from_api_credentials(json.loads(os.environ["MOONGRAM_TELEGRAM_API"]), args.kind)
        else:
            raise ValueError("Add the MOONGRAM_TELEGRAM_API repository secret, or a complete MOONGRAM_BUILD_CONFIG.")
        if os.environ.get("GITHUB_ACTIONS") == "true":
            # A JSON secret masks the whole value, so register the individual values too.
            for key in ("api_id", "api_hash"):
                print("::add-mask::" + config[key])
        write_private(args.output, config)
    except json.JSONDecodeError:
        raise SystemExit("Build configuration is not valid JSON; its content is omitted.")
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
    print("Private build configuration prepared (0600); credential values omitted.")


if __name__ == "__main__":
    main()
