#!/usr/bin/env python3
"""Scan current source or release payloads without printing matched secrets.

An optional local denylist supplies project-owner identifiers without putting
those identifiers in the public source or reports. This is a release gate, not
a replacement for reviewing imagery, dependency provenance and account access.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import subprocess
import zipfile
from pathlib import Path

RULES = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"),
    "access token": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{20,})"),
    # Reserved fixture names and GitHub's public runner identity are not people.
    "personal home path": re.compile(rb"(?<![A-Za-z0-9:/])/(?:Users|home)/(?!test/|example/|runner/)[A-Za-z0-9_.-]+/"),
}
PRIVATE_SUFFIXES = (".mobileprovision", ".provisionprofile", ".p12", ".pfx", ".p8", ".keychain", ".keychain-db")
MAX_MEMBER_BYTES = 1_500_000_000


def inspect_bytes(label: str, data: bytes, forbidden: list[str], allowlist: dict | None = None) -> list[str]:
    issues = [f"{label}: {name}" for name, pattern in RULES.items() if pattern.search(data)]
    folded = data.lower()
    for item in forbidden:
        if any(item.casefold().encode(encoding) in folded for encoding in ("utf-8", "utf-16-le", "utf-16-be")):
            issues.append(f"{label}: local denylist match")
            break
    if data.startswith(b"PK\x03\x04"):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                if sum(member.file_size for member in archive.infolist()) > MAX_MEMBER_BYTES:
                    return issues + [f"{label}: archive exceeds scan budget"]
                for member in archive.infolist():
                    if member.is_dir():
                        continue
                    issues.extend(inspect_payload(f"{label}!{member.filename}", archive.read(member), forbidden, allowlist))
        except (OSError, ValueError, zipfile.BadZipFile, RuntimeError):
            issues.append(f"{label}: archive could not be inspected")
    return issues


def inspect_payload(label: str, data: bytes, forbidden: list[str], allowlist: dict | None = None) -> list[str]:
    issues = inspect_bytes(label, data, forbidden, allowlist)
    if label.casefold().endswith(PRIVATE_SUFFIXES):
        issues.append(f"{label}: personal signing material")
    if any(term.casefold() in label.casefold() for term in forbidden):
        issues.append(f"{label}: local denylist filename match")
    # Exceptions are limited to reviewed, byte-identical upstream files and
    # individual rules. A package edit invalidates the exception automatically.
    for name, entry in (allowlist or {}).items():
        if ((label == name or label.endswith("/" + name))
                and hashlib.sha256(data).hexdigest() == entry["sha256"]):
            permitted = {f"{label}: {rule}" for rule in entry["rules"]}
            issues = [issue for issue in issues if issue not in permitted]
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", action="store_true", help="Inspect current Git files, including untracked nonignored files")
    parser.add_argument("--forbid-file", type=Path, help="Private UTF-8 newline-separated denylist; never commit this file")
    parser.add_argument("paths", type=Path, nargs="*")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    allow_path = root / "Config/PublicPayloadAllowlist.json"
    allowlist = json.loads(allow_path.read_text()) if allow_path.is_file() else {}
    forbidden = [s.strip() for s in args.forbid_file.read_text().splitlines() if s.strip()] if args.forbid_file else []
    paths: set[Path] = set()
    if args.source:
        names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root)
        paths.update(root / name.decode() for name in names.split(b"\0") if name)
    for target in args.paths:
        paths.update(target.rglob("*") if target.is_dir() else [target])
    if not args.source and not args.paths:
        parser.error("select --source or a payload path")
    issues: list[str] = []
    count = 0
    for path in sorted(paths):
        if not path.is_file() or path.is_symlink():
            continue
        count += 1
        try:
            label = str(path.relative_to(root)) if path.is_relative_to(root) else path.name
            issues.extend(inspect_payload(label, path.read_bytes(), forbidden, allowlist))
        except OSError:
            issues.append(f"{path.name}: could not be inspected")
    for issue in sorted(set(issues)):
        print(issue)
    print(f"Public package scan: {count} files, {len(set(issues))} findings.")
    return 1 if issues else 0


if __name__ == "__main__":
    raise SystemExit(main())
