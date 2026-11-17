#!/usr/bin/env python3
"""Restore or verify the separately pinned, bundled-only image extraction packages."""
import argparse
import hashlib
import json
import shutil
import tempfile
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "PythonApp/_image_packages"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--restore", action="store_true")
    parser.add_argument("--target", type=Path, default=TARGET, help="Runtime package directory to verify")
    args = parser.parse_args()
    target = args.target
    manifest = json.loads((ROOT / "Config/ImageDependencies.json").read_text())
    packages = manifest["packages"]
    if args.restore:
        with tempfile.TemporaryDirectory(prefix="illucet-images-") as temporary:
            stage = Path(temporary)
            for package in packages:
                with urllib.request.urlopen(package["url"], timeout=60) as response:
                    data = response.read(20 * 1024 * 1024 + 1)
                if len(data) > 20 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != package["sha256"]:
                    raise ValueError("image dependency integrity failure")
                archive = stage / package["filename"]
                archive.write_bytes(data)
                with zipfile.ZipFile(archive) as wheel:
                    for info in wheel.infolist():
                        path = PurePosixPath(info.filename)
                        if path.is_absolute() or ".." in path.parts or "\\" in info.filename or info.file_size > 20 * 1024 * 1024:
                            raise ValueError("unsafe image dependency wheel")
                    wheel.extractall(stage / "packages")
            directory = stage / "packages"
            # A content inventory makes offline verification detect changed code,
            # rather than trusting a distribution's version string alone.
            inventory = {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in directory.rglob("*") if p.is_file()}
            inventory_data = json.dumps(inventory, sort_keys=True).encode()
            if hashlib.sha256(inventory_data).hexdigest() != manifest["inventory_sha256"]:
                raise ValueError("restored image dependencies do not match the pinned inventory")
            (directory / "_inventory.json").write_bytes(inventory_data)
            if target.is_symlink():
                raise ValueError("image package destination is a symlink")
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(directory, target)
    inventory_data = (target / "_inventory.json").read_bytes()
    if hashlib.sha256(inventory_data).hexdigest() != manifest["inventory_sha256"]:
        raise ValueError("image dependency inventory does not match the pinned wheels")
    inventory = json.loads(inventory_data)
    actual = {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in target.rglob("*") if p.is_file() and p.name != "_inventory.json"
              and "__pycache__" not in p.parts and p.suffix != ".pyc"}
    if actual != inventory:
        raise ValueError("image dependency files changed; restore the pinned packages")
    expected_names = {p["name"].replace("-", "_") + "-" + p["version"] + ".dist-info" for p in packages}
    if {p.name for p in target.glob("*.dist-info")} != expected_names:
        raise ValueError("image dependency distributions do not match pins")
    print("Verified pinned image extraction packages.")


if __name__ == "__main__":
    main()
