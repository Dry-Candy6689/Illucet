#!/usr/bin/env python3
"""Check reviewed licenses and notices in the actual bundled Python packages.

This checks the inventory, not authorship or complete legal compliance.
"""
import argparse
import email
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def verify(root=ROOT, bundle=None):
    expected = {"yt-dlp": "Unlicense", "yt-dlp-ejs": "Unlicense AND MIT AND ISC", "certifi": "MPL-2.0"}
    manifest = json.loads((root / "Config/ImageDependencies.json").read_text())
    subprocess.run([sys.executable, str(root / "Scripts/image-dependencies.py"),
                    "--target", str((bundle or root) / "PythonApp/_image_packages")], check=True)
    expected.update({p["name"]: p["license"] for p in manifest["packages"]})
    actual = {}
    packages = bundle / "PythonPackages" if bundle else root / "Vendor/PythonPackages"
    for directory in (packages, (bundle or root) / "PythonApp/_image_packages"):
        for path in directory.glob("*.dist-info/METADATA"):
            metadata = email.message_from_bytes(path.read_bytes())
            name = metadata["Name"].lower().replace("_", "-")
            license = metadata["License-Expression"] or metadata["License"]
            if name in actual or name not in expected or license != expected[name]:
                raise ValueError("Unreviewed, duplicate, or changed runtime license: " + name)
            notices = [p for p in (path.parent / "licenses").rglob("*") if p.is_file() and p.stat().st_size > 0]
            if not notices:
                raise ValueError("Missing runtime license notice: " + name)
            actual[name] = license
    if actual != expected:
        raise ValueError("Bundled runtime license inventory is incomplete")
    if "Version 3, 29 June 2007" not in (root / "LICENSE").read_text():
        raise ValueError("Application license changed; compatibility must be reviewed again")
    token = json.loads((root / "Config/TokenProvider.json").read_text())
    for name, digest in token["files"].items():
        file = root / name
        if bundle and name.startswith("IllucetApp/TokenResources/"):
            file = bundle / file.name
        if hashlib.sha256(file.read_bytes()).hexdigest() != digest:
            raise ValueError("Token provider provenance hash mismatch: " + name)
    upstream = json.loads((root / "TokenProvider/upstream/package.json").read_text())
    if (upstream["name"], upstream["version"], upstream["license"]) != ("bgutils-js", token["version"], "MIT"):
        raise ValueError("Token provider license or version changed")
    notice = (bundle or root / "IllucetApp/TokenResources") / "BgUtils-LICENSE.txt"
    if notice.read_bytes() != (root / "TokenProvider/upstream/LICENSE").read_bytes():
        raise ValueError("Bundled BgUtils notice changed")
    aria = json.loads((root / "Config/Aria2.json").read_text())
    notices = ((bundle or root / "docs") / "ThirdPartyNotices.txt").read_text()
    if ("aria2 " + aria["version"] not in notices or "version 2 of the License" not in notices
            or "(at your option) any later version" not in notices):
        raise ValueError("Missing aria2 version or GPL-2.0-or-later notice")
    framework = root / "Vendor/Frameworks/IllucetAria2.xcframework"
    if framework.is_dir():
        provenance = json.loads((framework / "Provenance.json").read_text())
        if provenance["version"] != aria["version"] or provenance["sourceSHA256"] != aria["source"]["sha256"]:
            raise ValueError("aria2 provenance changed")
        for name, digest in provenance["libraries"].items():
            if hashlib.sha256((framework / name).read_bytes()).hexdigest() != digest:
                raise ValueError("aria2 native archive changed")
    print(f"Verified {len(actual)} Python distribution licenses and the BgUtils source, bundle and notice.")
    print("Verified aria2 GPL-2.0-or-later notice and available native provenance.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    verify(bundle=parser.parse_args().bundle)
