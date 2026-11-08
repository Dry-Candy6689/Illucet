#!/usr/bin/env python3
"""Restore only pinned runtime payloads after digest and member validation."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

ALLOWED = (
    "Vendor/Frameworks/Python.xcframework",
    "Vendor/Frameworks/QuickJS.xcframework",
    "Vendor/Frameworks/IllucetMedia.xcframework",
    "Vendor/PythonPackages",
)


def validate_members(archive: zipfile.ZipFile) -> None:
    seen: set[str] = set()
    for member in archive.infolist():
        name = member.filename.rstrip("/")
        path = PurePosixPath(name)
        if (not name or path.is_absolute() or ".." in path.parts or "\\" in name
                or any(ord(c) < 32 for c in name)
                or not any(name == allowed or name.startswith(allowed + "/") for allowed in ALLOWED)
                or name in seen or stat.S_IFMT(member.external_attr >> 16) not in (0, stat.S_IFREG, stat.S_IFDIR)):
            raise ValueError("unsafe, duplicate or unexpected runtime archive member")
        seen.add(name)
    if sum(info.file_size for info in archive.infolist()) > 1_500_000_000:
        raise ValueError("runtime archive exceeds size limit")


def restore(source: Path, root: Path) -> None:
    root = root.resolve(strict=True)
    expected = json.loads((root / "Config/RuntimeRelease.json").read_text())["sha256"]
    with source.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != expected:
        raise ValueError("runtime SHA-256 verification failed")
    with zipfile.ZipFile(source) as archive, tempfile.TemporaryDirectory(prefix="illucet-runtime-") as work:
        validate_members(archive)
        stage = Path(work)
        archive.extractall(stage)
        for member in archive.infolist():
            mode = (member.external_attr >> 16) & 0o777
            if mode:
                (stage / member.filename).chmod(mode)
        for relative in ALLOWED:
            path = stage / relative
            required = path / "yt_dlp/version.py" if relative.endswith("PythonPackages") else path / "Info.plist"
            if not required.is_file():
                raise ValueError("runtime archive is missing a required component")
        replacements: list[tuple[Path, Path | None]] = []
        try:
            for relative in ALLOWED:
                target = root / relative
                if (target.is_symlink() or not target.resolve().is_relative_to(root)
                        or (target.exists() and not target.is_dir())):
                    raise ValueError("runtime destination must be a contained directory")
                target.parent.mkdir(parents=True, exist_ok=True)
                backup = target.with_name(target.name + ".restore-backup") if target.exists() else None
                if backup and backup.exists():
                    raise ValueError("previous runtime restore backup needs review")
                if backup:
                    os.replace(target, backup)
                replacements.append((target, backup))
                shutil.copytree(stage / relative, target)
        except BaseException:
            for target, backup in reversed(replacements):
                if target.exists():
                    shutil.rmtree(target)
                if backup:
                    os.replace(backup, target)
            raise
        for _, backup in replacements:
            if backup:
                shutil.rmtree(backup)
    print("Verified runtime dependencies restored.")


if __name__ == "__main__":
    restore(Path(sys.argv[1]), Path(sys.argv[2]).resolve())
