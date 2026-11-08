"""Bounded, offline package staging. Never import or execute downloaded code here."""

from __future__ import annotations

import ast
import gzip
import hashlib
from io import BytesIO
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
import tomllib
import zipfile

PACKAGES = {"yt-dlp": "yt_dlp", "yt-dlp-ejs": "yt_dlp_ejs", "certifi": "certifi"}
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_EXPANDED = 128 * 1024 * 1024
MAX_MEMBERS = 10000
MAX_MASTER_METADATA = 64 * 1024
EXECUTABLE_SUFFIXES = {".so", ".dylib", ".dll", ".pth", ".pyc", ".pyo", ".exe", ".a", ".o", ".bundle"}
# Official wheel documentation/completions are irrelevant on iOS. Validate their
# entry shape and account for their sizes, but never install them into sys.path.
YTDLP_UNUSED_DATA = {
    "data/share/bash-completion/completions/yt-dlp",
    "data/share/doc/yt_dlp/README.txt",
    "data/share/fish/vendor_completions.d/yt-dlp.fish",
    "data/share/man/man1/yt-dlp.1",
    "data/share/zsh/site-functions/_yt-dlp",
}


def _literal_assignments(source: str, names: set[str]) -> dict:
    values = {}
    tree = ast.parse(source)
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in names:
                    if target.id in values:
                        raise ValueError("Duplicate package identity")
                    values[target.id] = ast.literal_eval(node.value)
    return values


def _literal_version(path: Path) -> str:
    value = _literal_assignments(path.read_text(encoding="utf-8"), {"__version__"}).get("__version__")
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*(?:\.dev[0-9]+)?", value):
        raise ValueError("Package runtime version is invalid")
    return value


def _verified_archive(record: dict) -> Path:
    archive = Path(record["path"])
    if archive.is_symlink() or not archive.is_file() or archive.stat().st_size > MAX_ARCHIVE:
        raise ValueError("Invalid package archive")
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != record["sha256"]:
        raise ValueError("Package integrity check failed")
    return archive


class _BoundedTarReader:
    """Count the actual inflated stream, including tar headers and padding."""

    def __init__(self, stream):
        self.stream = stream
        self.remaining = MAX_EXPANDED

    def read(self, size: int) -> bytes:
        chunk = self.stream.read(min(size, self.remaining + 1))
        self.remaining -= len(chunk)
        if self.remaining < 0:
            raise ValueError("Master archive expansion limit exceeded")
        return chunk


def _copy_member(source, target: Path, size: int):
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("xb") as output:
        remaining = size
        while chunk := source.read(256 * 1024):
            remaining -= len(chunk)
            if remaining < 0:
                raise ValueError("Invalid package member size")
            output.write(chunk)
        if remaining:
            raise ValueError("Truncated package member")
    os.chmod(target, 0o600)


def _read_master_archive(record: dict, root: Path | None = None) -> tuple[dict, int, int]:
    if record.get("package") != "yt-dlp" or record.get("format") != "masterSource":
        raise ValueError("Unexpected Master archive")
    archive = _verified_archive(record)
    metadata = {}
    seen: set[str] = set()
    total = 0
    members = 0
    with gzip.open(archive, "rb") as stream, tarfile.open(fileobj=_BoundedTarReader(stream), mode="r|") as tar:
        for member in tar:
            members += 1
            total += member.size
            if members > MAX_MEMBERS or total > MAX_EXPANDED:
                raise ValueError("Master archive expansion limit exceeded")
            name = member.name
            parts = name.rstrip("/").split("/")
            folded = name.rstrip("/").casefold()
            if (parts[0] != "yt-dlp" or any(part in ("", ".", "..") for part in parts)
                or any(ord(character) < 32 for character in name) or "\\" in name
                or folded in seen or not (member.isfile() or member.isdir())
                or member.issparse() or member.size < 0):
                raise ValueError("Unsafe Master archive member")
            seen.add(folded)
            relative = PurePosixPath(*parts[1:])
            in_package = relative.parts[:1] == ("yt_dlp",)
            if in_package and relative.suffix.lower() in EXECUTABLE_SUFFIXES:
                raise ValueError("Executable or import-hook Master member")
            if member.isdir():
                if root is not None and in_package:
                    root.joinpath(*relative.parts).mkdir(parents=True, exist_ok=True)
                continue
            if str(relative) in {"pyproject.toml", "yt_dlp/version.py"}:
                if member.size > MAX_MASTER_METADATA:
                    raise ValueError("Master metadata is too large")
                with tar.extractfile(member) as source:
                    content = source.read(member.size)
                if len(content) != member.size:
                    raise ValueError("Truncated Master metadata")
                metadata[str(relative)] = content.decode("utf-8")
                if root is not None and in_package:
                    _copy_member(BytesIO(content), root.joinpath(*relative.parts), member.size)
            elif root is not None and in_package:
                with tar.extractfile(member) as source:
                    _copy_member(source, root.joinpath(*relative.parts), member.size)
    version = _literal_assignments(metadata["yt_dlp/version.py"], {"__version__", "CHANNEL", "ORIGIN"})
    if version != {"__version__": record["version"], "CHANNEL": "master", "ORIGIN": "yt-dlp/yt-dlp-master-builds"}:
        raise ValueError("Master release identity did not match")
    project = tomllib.loads(metadata["pyproject.toml"])["project"]
    pins = project["optional-dependencies"]["pin"]
    if project["name"] != "yt-dlp" or not isinstance(pins, list) or not all(isinstance(pin, str) for pin in pins):
        raise ValueError("Invalid Master dependency metadata")
    return {"requiresPython": project["requires-python"], "requirements": pins}, members, total


def inspect_master_archive(record: dict) -> dict:
    requirements, _, _ = _read_master_archive(record)
    return requirements


def extract_packages(archives: list[dict], destination: str) -> dict[str, str]:
    root = Path(destination)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir() or any(root.iterdir()):
        raise ValueError("Package staging directory must be empty and regular")
    if len(archives) != 3 or {archive.get("package") for archive in archives} != set(PACKAGES):
        raise ValueError("Unexpected package set")
    total = 0
    members = 0
    seen: set[str] = set()
    for wheel in archives:
        package = PACKAGES[wheel["package"]]
        kind = wheel.get("format", "wheel")
        if kind == "masterSource":
            _, count, expanded = _read_master_archive(wheel, root)
            members += count
            total += expanded
            if members > MAX_MEMBERS or total > MAX_EXPANDED:
                raise ValueError("Package expansion limit exceeded")
            if not (root / package / "__init__.py").is_file():
                raise ValueError("Package entry point missing")
            continue
        if kind != "wheel":
            raise ValueError("Unexpected package format")
        archive = _verified_archive(wheel)
        version = wheel["version"]
        metadata = f"{package}-{version}.dist-info"
        with zipfile.ZipFile(archive) as zipped:
            for info in zipped.infolist():
                members += 1
                total += info.file_size
                if members > MAX_MEMBERS or total > MAX_EXPANDED:
                    raise ValueError("Wheel expansion limit exceeded")
                name = info.filename
                path = PurePosixPath(name)
                mode = info.external_attr >> 16
                unused_data = wheel["package"] == "yt-dlp" and name in {
                    f"{package}-{version}.data/{entry}" for entry in YTDLP_UNUSED_DATA
                }
                if (not name or "\\" in name or "\x00" in info.orig_filename
                    or path.is_absolute() or any(part in (".", "..") for part in name.rstrip("/").split("/"))
                    or (path.parts[0] not in (package, metadata) and not unused_data)
                    or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR))
                    or info.flag_bits & 1):
                    raise ValueError("Unsafe wheel member")
                if path.suffix.lower() in EXECUTABLE_SUFFIXES:
                    raise ValueError("Executable or import-hook wheel member")
                folded = str(path).casefold()
                if folded in seen:
                    raise ValueError("Duplicate wheel member")
                seen.add(folded)
                if unused_data:
                    continue
                target = root.joinpath(*path.parts)
                if info.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                with zipped.open(info) as source:
                    _copy_member(source, target, info.file_size)
        if not (root / package / "__init__.py").is_file():
            raise ValueError("Package entry point missing")
    versions = {
        "ytDLP": _literal_version(root / "yt_dlp/version.py"),
        "ejs": _literal_version(root / "yt_dlp_ejs/_version.py"),
        # certifi runtime dates are zero-padded; PyPI normalizes each numeric
        # distribution component (2026.07.22 -> 2026.7.22).
        "certifi": ".".join(str(int(part)) for part in
            _literal_version(root / "certifi/__init__.py").split(".")),
    }
    return versions
