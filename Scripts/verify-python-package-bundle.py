#!/usr/bin/env python3
"""Fail closed when bundled Stage 0 Python packages do not match their pins."""

from __future__ import annotations

import argparse
from email.parser import Parser
from pathlib import Path
import re
import sys


PIN_PATTERN = re.compile(r'^([A-Z][A-Z0-9_]*)="([^"]*)"$')
MODULE_VERSION_PATTERN = re.compile(
    r"^__version__\s*=\s*(['\"])([^'\"]+)\1\s*$",
    re.MULTILINE,
)
REQUIRED_DISTRIBUTIONS = {
    "yt-dlp": "YTDLP_VERSION",
    "yt-dlp-ejs": "YTDLP_EJS_VERSION",
    "certifi": "CERTIFI_VERSION",
}


class VerificationError(RuntimeError):
    pass


def load_pins(config_path: Path) -> dict[str, str]:
    pins: dict[str, str] = {}
    for line in config_path.read_text(encoding="utf-8").splitlines():
        match = PIN_PATTERN.fullmatch(line.strip())
        if match is not None:
            pins[match.group(1)] = match.group(2)
    missing = sorted(set(REQUIRED_DISTRIBUTIONS.values()) - pins.keys())
    if missing:
        raise VerificationError(
            f"dependency config is missing required pins: {', '.join(missing)}"
        )
    return pins


def canonical_numeric_version(version: str) -> str:
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)*)(?:\.?dev([0-9]*))?", version)
    if match is None:
        raise VerificationError(f"unsupported version: {version}")
    release = ".".join(str(int(part)) for part in match[1].split("."))
    return release + (f".dev{int(match[2] or '0')}" if match[2] is not None else "")


def installed_distributions(package_root: Path) -> dict[str, list[str]]:
    distributions: dict[str, list[str]] = {}
    for metadata_path in sorted(package_root.glob("*.dist-info/METADATA")):
        metadata = Parser().parsestr(metadata_path.read_text(encoding="utf-8"))
        name = metadata.get("Name")
        version = metadata.get("Version")
        if not name or not version:
            raise VerificationError(
                f"distribution metadata is missing Name or Version: {metadata_path}"
            )
        distributions.setdefault(name.lower().replace("_", "-"), []).append(
            version
        )
    return distributions


def verify_bundle(config_path: Path, package_root: Path) -> dict[str, str]:
    if not package_root.is_dir():
        raise VerificationError(f"Python package bundle is missing: {package_root}")

    pins = load_pins(config_path)
    distributions = installed_distributions(package_root)
    unexpected = sorted(set(distributions) - set(REQUIRED_DISTRIBUTIONS))
    if unexpected:
        raise VerificationError(
            f"Python package bundle contains unexpected distributions: "
            f"{', '.join(unexpected)}"
        )

    verified: dict[str, str] = {}
    for distribution, pin_name in REQUIRED_DISTRIBUTIONS.items():
        versions = distributions.get(distribution, [])
        if len(versions) != 1:
            raise VerificationError(
                f"expected exactly one {distribution} distribution, found "
                f"{len(versions)}"
            )
        expected_pin = pins.get("YTDLP_PACKAGE_VERSION", pins[pin_name]) \
            if distribution == "yt-dlp" else pins[pin_name]
        expected = canonical_numeric_version(expected_pin)
        actual = canonical_numeric_version(versions[0])
        if actual != expected:
            raise VerificationError(
                f"{distribution} version mismatch: expected {pins[pin_name]}, "
                f"found {versions[0]}"
            )
        verified[distribution] = versions[0]

    version_path = package_root / "yt_dlp" / "version.py"
    if not version_path.is_file():
        raise VerificationError(f"yt-dlp version module is missing: {version_path}")
    match = MODULE_VERSION_PATTERN.search(version_path.read_text(encoding="utf-8"))
    if match is None:
        raise VerificationError("yt-dlp version module has no __version__ assignment")
    module_version = match.group(2)
    if module_version != pins["YTDLP_VERSION"]:
        raise VerificationError(
            f"yt-dlp runtime version mismatch: expected {pins['YTDLP_VERSION']}, "
            f"found {module_version}"
        )

    return verified


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("package_root", type=Path)
    arguments = parser.parse_args()
    try:
        verified = verify_bundle(arguments.config, arguments.package_root)
    except (OSError, UnicodeError, VerificationError) as error:
        print(f"Python package bundle verification failed: {error}", file=sys.stderr)
        return 1

    summary = ", ".join(
        f"{name} {version}" for name, version in verified.items()
    )
    print(f"Verified Python package bundle: {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
