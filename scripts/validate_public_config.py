#!/usr/bin/env python3
"""Read-only public build-config validation. No network, login, device or writes."""
import argparse
import json
from pathlib import Path
import re
import sys
from urllib.parse import parse_qsl, urlsplit

REFERENCE_CLIENT_ID = "58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo"
OWN_REDIRECT = "recording-card://callback"
REFERENCE_REDIRECT = "reai-mobile://callback"
FLAGS = frozenset({
    "RC_OAUTH_REUSE_REFERENCE_CLIENT", "RC_ASR_ALLOW_DOWNLOAD",
    "RC_ASR_LICENSE_ACCEPTED", "RC_UPLOAD_RAW_CONTRACT_APPROVED",
    "RC_UPLOAD_OAUTH_BEARER_APPROVED", "RC_ASR_LOCAL_ARTIFACTS_APPROVED",
})
STRING_KEYS = frozenset({
    "RC_AUTH_MODE", "RC_API_BASE", "RC_OAUTH_CLIENT_ID", "RC_OAUTH_BASE_URL",
    "RC_OAUTH_REDIRECT_URI", "RC_OAUTH_SCOPE", "RC_MODEL_GATEWAY_BASE_URL",
    "RC_TEXT_MODEL", "RC_ASR_MODEL_URL", "RC_ASR_TOKENS_URL",
    "RC_ASR_DOWNLOAD_HOSTS", "RC_VAD_URL", "RC_VAD_SHA256", "RC_UPLOAD_URL",
    "RC_UPLOAD_HOSTS", "RC_FIRMWARE_MANIFEST_JSON", "RC_ASR_ARTIFACT_PROFILE",
})
SECRET_MARKERS = ("secret", "password", "access_token", "refresh_token",
                  "api_key", "apikey", "private_key", "authorization")
COLLISION_WARNING = (
    "WARNING: explicit reference-client reuse enabled. On iOS, keep only recording-card "
    "globally registered and capture reai-mobile through ASWebAuthenticationSession; "
    "do not uninstall the reference app. Android requires a separate test device if "
    "another installed app registers reai-mobile. Token storage remains recording_card."
)


class ConfigError(ValueError):
    pass


def _no_secrets(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if any(marker in key.lower() for marker in SECRET_MARKERS):
                raise ConfigError("Secrets/credentials are prohibited in public build config")
            _no_secrets(child)
    elif isinstance(value, list):
        for child in value:
            _no_secrets(child)


def parse_flag(config, key):
    value = config.get(key, False)
    if value is True or value == "true":
        return True
    if value is False or value == "false":
        return False
    raise ConfigError(f"{key} must be JSON true/false or the exact string true/false")


def _hosts(config, key):
    value = config.get(key, "")
    if not value:
        return set()
    result = set()
    for part in value.split(","):
        host = part.strip().lower()
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", host) or ".." in host:
            raise ConfigError(f"{key} must contain exact host names, not URLs/wildcards/ports")
        result.add(host)
    return result


def _https(config, key, hosts=None):
    value = config.get(key, "")
    if not value:
        return
    try:
        uri = urlsplit(value)
        valid = (value == value.strip() and not any(c.isspace() for c in value)
                 and uri.scheme == "https" and bool(uri.hostname)
                 and uri.username is None and uri.password is None
                 and not uri.fragment and uri.port in (None, 443))
        if hosts is not None:
            valid = valid and uri.hostname.lower() in hosts
        if any(any(marker in key.lower() for marker in SECRET_MARKERS)
               or key.lower() in {"token", "key"} for key, _ in parse_qsl(uri.query)):
            valid = False
    except ValueError:
        valid = False
    if not valid:
        raise ConfigError(f"{key} requires credential-free HTTPS on port 443"
                          + (" and an explicit allowed host" if hosts is not None else ""))


def validate_config(config):
    """Return a safe known scheme, never user-supplied xcconfig source text."""
    if not isinstance(config, dict):
        raise ConfigError("Public config must be a JSON object")
    _no_secrets(config)
    for key, value in config.items():
        if key not in STRING_KEYS | FLAGS | {"RC_VAD_SIZE"}:
            raise ConfigError(f"Unknown public config key: {key}")
        if key in STRING_KEYS and not isinstance(value, str):
            raise ConfigError(f"{key} must be a string")
    flags = {key: parse_flag(config, key) for key in FLAGS}
    profile = config.get("RC_ASR_ARTIFACT_PROFILE", "sensevoice-mobile-20240717")
    if profile not in {"sensevoice-mobile-20240717", "reai-vibe-board-local-20261109"}:
        raise ConfigError("Unknown fixed ASR artifact profile")
    if profile == "reai-vibe-board-local-20261109":
        if not flags["RC_ASR_LOCAL_ARTIFACTS_APPROVED"] or not flags["RC_ASR_LICENSE_ACCEPTED"]:
            raise ConfigError("Local ASR profile requires explicit artifact approval and license acceptance")
        if flags["RC_ASR_ALLOW_DOWNLOAD"] or any(config.get(k) for k in (
            "RC_ASR_MODEL_URL", "RC_ASR_TOKENS_URL", "RC_ASR_DOWNLOAD_HOSTS",
            "RC_VAD_URL", "RC_VAD_SHA256", "RC_VAD_SIZE",
        )):
            raise ConfigError("Local ASR profile is pinned and local-only; download/VAD overrides are prohibited")
    elif flags["RC_ASR_LOCAL_ARTIFACTS_APPROVED"]:
        raise ConfigError("Local artifact approval requires the explicit local profile")
    client = config.get("RC_OAUTH_CLIENT_ID", "")
    if not client or client != client.strip() or any(c.isspace() for c in client):
        raise ConfigError("RC_OAUTH_CLIENT_ID must explicitly name an approved public client")
    reuse = flags["RC_OAUTH_REUSE_REFERENCE_CLIENT"]
    expected = REFERENCE_REDIRECT if reuse else OWN_REDIRECT
    if config.get("RC_OAUTH_REDIRECT_URI") != expected:
        raise ConfigError(f"RC_OAUTH_REDIRECT_URI must be exactly {expected}; reuse requires explicit opt-in")
    if reuse and client != REFERENCE_CLIENT_ID:
        raise ConfigError("Reference-client reuse only permits the agreed reference public client ID")

    for key in ("RC_API_BASE", "RC_OAUTH_BASE_URL", "RC_MODEL_GATEWAY_BASE_URL"):
        _https(config, key)
    download_hosts = _hosts(config, "RC_ASR_DOWNLOAD_HOSTS")
    for key in ("RC_ASR_MODEL_URL", "RC_ASR_TOKENS_URL", "RC_VAD_URL"):
        _https(config, key, download_hosts)
    if flags["RC_ASR_ALLOW_DOWNLOAD"] and (
        not flags["RC_ASR_LICENSE_ACCEPTED"] or not download_hosts
        or not config.get("RC_ASR_MODEL_URL") or not config.get("RC_ASR_TOKENS_URL")
    ):
        raise ConfigError("ASR download requires license acceptance, audited model/tokens URLs and exact hosts")
    size = config.get("RC_VAD_SIZE", 0)
    if isinstance(size, bool) or not isinstance(size, (int, str)) or not re.fullmatch(r"[0-9]+", str(size)):
        raise ConfigError("RC_VAD_SIZE must be a nonnegative integer")
    digest = config.get("RC_VAD_SHA256", "")
    if config.get("RC_VAD_URL") or digest or int(size):
        if int(size) <= 0 or not re.fullmatch(r"[a-fA-F0-9]{64}", digest):
            raise ConfigError("Configured VAD requires an exact positive size and SHA256")
        if flags["RC_ASR_ALLOW_DOWNLOAD"] and not config.get("RC_VAD_URL"):
            raise ConfigError("VAD download requires an audited URL")
    upload_hosts = _hosts(config, "RC_UPLOAD_HOSTS")
    _https(config, "RC_UPLOAD_URL", upload_hosts)
    if flags["RC_UPLOAD_RAW_CONTRACT_APPROVED"] and not config.get("RC_UPLOAD_URL"):
        raise ConfigError("Approved upload requires an explicit URL and hosts")
    if flags["RC_UPLOAD_OAUTH_BEARER_APPROVED"] and not flags["RC_UPLOAD_RAW_CONTRACT_APPROVED"]:
        raise ConfigError("OAuth bearer upload requires explicit raw-upload contract approval")
    if config.get("RC_FIRMWARE_MANIFEST_JSON"):
        try:
            _no_secrets(json.loads(config["RC_FIRMWARE_MANIFEST_JSON"]))
        except json.JSONDecodeError as error:
            raise ConfigError("RC_FIRMWARE_MANIFEST_JSON must be JSON") from error
    # RC_TEXT_MODEL may be empty: select from the authorized directory after login.
    return "reai-mobile" if reuse else "recording-card"


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ConfigError("Duplicate JSON key in public config")
        result[key] = value
    return result


def load_config(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=_unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ConfigError("Cannot read public config as UTF-8 JSON; use an approved public config file") from error


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", help="approved public JSON config; never a credential file")
    parser.add_argument("--scheme", action="store_true", help="print only the safe native scheme to stdout")
    args = parser.parse_args(argv)
    try:
        scheme = validate_config(load_config(args.config))
    except ConfigError as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 2
    if scheme == "reai-mobile":
        print(COLLISION_WARNING, file=sys.stderr)
    print(scheme if args.scheme else f"Public config valid; native callback = {scheme}://callback. No network/device operation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
