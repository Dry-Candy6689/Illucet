#!/usr/bin/env python3
"""Resolve an exact Stable, Nightly or pinned build profile from official PyPI metadata.

Prints a complete dependency config by default; --apply replaces only Python pins
in Config/Dependencies.sh. Fetch packages and sync generated expectations afterward.
No package code is downloaded or executed by this selector.
"""
import argparse
from datetime import date
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit
from urllib.request import build_opener, HTTPRedirectHandler, Request

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 1_048_576


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch(package, version):
    url = f"https://pypi.org/pypi/{package}/{version}/json"
    with build_opener(NoRedirects).open(Request(url, headers={"User-Agent": "Illucet/1"}), timeout=30) as response:
        data = response.read(LIMIT + 1)
        if response.status != 200 or response.url != url or len(data) > LIMIT:
            raise ValueError("Invalid official metadata response")
    return json.loads(data)


def distribution_version(profile, release):
    if profile not in {"stable", "nightly", "pinned"}:
        raise ValueError("Unknown profile")
    if not re.fullmatch(r"[0-9]{4}\.[0-9]{2}\.[0-9]{2}(?:\.[0-9]{1,12})?", release):
        raise ValueError("Use an exact runtime release, YYYY.MM.DD[.BUILD]")
    parts = [int(part) for part in release.split(".")]
    date(*parts[:3])
    nightly = len(parts) == 4
    if (profile == "stable" and nightly) or (profile == "nightly" and not nightly):
        raise ValueError("Release does not match the selected channel")
    return ".".join(map(str, parts)) + (".dev0" if nightly else "")


def dependency(name, requirements):
    if not isinstance(requirements, list) or len(requirements) > 500:
        raise ValueError("Missing exact dependency pins")
    versions = set()
    for item in requirements:
        if not isinstance(item, str) or len(item) > 2048:
            raise ValueError("Invalid dependency metadata")
        spec = item.split(";", 1)[0].strip()
        if spec.startswith(name + "=="):
            value = spec[len(name) + 2:]
            if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
                raise ValueError("Unsupported dependency pin")
            versions.add(value)
    if len(versions) != 1:
        raise ValueError("Missing or conflicting exact dependency pins")
    return versions.pop()


def artifact(metadata, package, version):
    info = metadata["info"]
    python = info.get("requires_python", "")
    if (info["name"].replace("_", "-") != package or info["version"] != version
            or info.get("yanked", False) is not False
            or not isinstance(python, str) or not re.fullmatch(r">=3\.[0-9]{1,2}", python)
            or int(python[4:]) > 15):
        raise ValueError("Incompatible package metadata")
    filename = f"{package.replace('-', '_')}-{version}-py3-none-any.whl"
    wheels = [item for item in metadata["urls"] if item.get("filename") == filename]
    if len(wheels) != 1:
        raise ValueError("Expected one universal Python wheel")
    wheel = wheels[0]
    url = urlsplit(wheel["url"])
    digest = wheel["digests"]["sha256"]
    if (wheel.get("yanked") is not False or wheel.get("packagetype") != "bdist_wheel"
            or type(wheel.get("size")) is not int or not 0 < wheel["size"] <= 32 * 1024 * 1024
            or not re.fullmatch(r"[a-f0-9]{64}", digest)
            or url.scheme != "https" or url.netloc != "files.pythonhosted.org"
            or url.query or url.fragment or not url.path.startswith("/packages/")
            or url.path.rsplit("/", 1)[-1] != filename or "%" in url.path
            or "\\" in url.path or ".." in url.path.split("/")):
        raise ValueError("Unsafe or invalid wheel metadata")
    return filename, digest


def resolve(profile, release, load=fetch):
    version = distribution_version(profile, release)
    metadata = load("yt-dlp", version)
    wheel, digest = artifact(metadata, "yt-dlp", version)
    pins = {"YTDLP_PROFILE": profile, "YTDLP_VERSION": release,
            "YTDLP_PACKAGE_VERSION": version, "YTDLP_WHEEL": wheel, "YTDLP_SHA256": digest}
    for package, prefix in (("yt-dlp-ejs", "YTDLP_EJS"), ("certifi", "CERTIFI")):
        dep_version = dependency(package, metadata["info"].get("requires_dist"))
        dep_wheel, dep_digest = artifact(load(package, dep_version), package, dep_version)
        pins.update({prefix + "_VERSION": dep_version, prefix + "_WHEEL": dep_wheel,
                     prefix + "_SHA256": dep_digest})
    return pins


def render(source, pins):
    for name, value in pins.items():
        pattern = rf'^{name}="[^"\n]*"$'
        if len(re.findall(pattern, source, re.M)) != 1:
            raise ValueError(f"Expected exactly one {name} pin")
        source = re.sub(pattern, lambda _: f'{name}="{value}"', source, flags=re.M)
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("stable", "nightly", "pinned"), required=True)
    parser.add_argument("--version", required=True, help="Exact runtime release; never a moving latest alias")
    parser.add_argument("--apply", action="store_true", help="Write verified Python pins to Config/Dependencies.sh")
    args = parser.parse_args()
    path = ROOT / "Config/Dependencies.sh"
    try:
        source = path.read_text()
        result = render(source, resolve(args.profile, args.version))
        if args.apply:
            if path.read_text() != source:
                raise ValueError("Dependency config changed during resolution")
            temporary = path.with_suffix(".sh.profile-tmp")
            try:
                temporary.write_text(result)
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
            print("Python pins updated. Fetch Python packages, sync expectations, then run validation.")
        else:
            print(result, end="")
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"Profile selection failed: {error}\n")


if __name__ == "__main__":
    main()
