#!/usr/bin/env python3
"""Package exact native source inputs and build scripts with neutral metadata."""
from __future__ import annotations

import gzip
import hashlib
import json
import http.client
import ssl
import tempfile
import time
import urllib.error
import re
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path


def download_source(url: str, path: Path, expected_sha: str) -> None:
    """Retry transient transport failures; cache only a complete verified archive."""
    path.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(3):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, suffix=".part", delete=False) as stream:
                temporary = Path(stream.name)
                checksum = hashlib.sha256()
                with urllib.request.urlopen(url, timeout=60) as response:
                    while chunk := response.read(1024 * 1024):
                        stream.write(chunk)
                        checksum.update(chunk)
            if checksum.hexdigest() != expected_sha:
                raise ValueError("native source input failed SHA-256 verification")
            temporary.replace(path)
            return
        except (urllib.error.URLError, ConnectionError, TimeoutError, http.client.IncompleteRead) as error:
            if isinstance(error, urllib.error.HTTPError):
                retryable = error.code in (408, 429, 500, 502, 503, 504)
                error.close()
            else:
                reason = getattr(error, "reason", error)
                retryable = isinstance(reason, (ConnectionError, TimeoutError, http.client.IncompleteRead))
                if isinstance(reason, ssl.SSLCertVerificationError):
                    retryable = False
            if not retryable or attempt == 2:
                raise
            print(f"Retrying source download: {path.name} (attempt {attempt + 2}/3)", flush=True)
            time.sleep(2 ** attempt)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


def package(root: Path, output: Path) -> None:
    pins = dict(re.findall(r'^([A-Z0-9_]+)="([^"]*)"', (root / "Config/Dependencies.sh").read_text(), re.M))
    entries = [{"archive": pins[name + "_ARCHIVE"], "sha256": pins[name + "_SHA256"], "url": pins[name + "_URL"]}
               for name in ("CPYTHON", "QUICKJS", "FFMPEG", "LAME")]
    entries.extend(json.loads((root / "Config/NativeSupportSources.json").read_text()))
    files: list[tuple[Path, str]] = []
    for entry in entries:
        path = root / "Vendor/Downloads" / entry["archive"]
        if not path.is_file():
            download_source(entry["url"], path, entry["sha256"])
        with path.open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != entry["sha256"]:
            raise ValueError("native source input failed SHA-256 verification")
        files.append((path, "upstream/" + path.name))
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
    for name in sorted(set(names)):
        if name.startswith(("Config/", "Patches/", "Scripts/")) and (root / name).is_file():
            files.append((root / name, name))
    for relative in ("LICENSE", "Vendor/PythonSourceDeps.sha256", "docs/Licenses.md", "docs/ThirdPartyNotices.txt", "docs/BuildFromScratch.md"):
        files.append((root / relative, relative))
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError("refusing to replace an existing source package")
    with output.open("xb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as zipped, tarfile.open(fileobj=zipped, mode="w") as archive:
        for path, name in sorted(files, key=lambda pair: pair[1]):
            info = archive.gettarinfo(str(path), arcname="Illucet-native-sources/" + name)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            with path.open("rb") as stream:
                archive.addfile(info, stream)
    print(f"Native source package: {len(entries)} verified upstream archives, complete build scripts and notices.")


if __name__ == "__main__":
    package(Path(__file__).resolve().parents[1], Path(sys.argv[1]).resolve())
