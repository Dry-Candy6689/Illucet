#!/usr/bin/env python3
"""Validate app identity and optionally reject retired names in current files."""
from __future__ import annotations

import argparse
import plistlib
import subprocess
from pathlib import Path


def retired_references(paths: list[Path], root: Path, forbidden: list[str]) -> list[str]:
    issues = []
    terms = [term.casefold().encode() for term in forbidden if term]
    for path in paths:
        if not path.is_file() or path.is_symlink():
            continue
        relative = str(path.relative_to(root))
        if any(term in relative.casefold().encode() for term in terms):
            issues.append(f"retired name in filename: {relative}")
        if terms:
            data = path.read_bytes().lower()
            if any(term in data for term in terms):
                issues.append(f"retired name in content: {relative}")
    return issues


def verify_identity(root: Path) -> list[str]:
    issues = []
    config = (root / "Config/Base.xcconfig").read_text()
    for value in ("ILLUCET_APP_NAME = Illucet", "ILLUCET_BUNDLE_ID = com.local.illucet"):
        if value not in config:
            issues.append(f"missing canonical identity: {value}")
    shortcut = plistlib.loads((root / "Shortcuts/Download with Illucet.plist").read_bytes())
    if shortcut.get("WFWorkflowName") != "Download with Illucet":
        issues.append("shortcut name does not match app identity")
    descriptors = [action.get("WFWorkflowActionParameters", {}).get("AppIntentDescriptor")
                   for action in shortcut.get("WFWorkflowActions", [])]
    if not any(item and item.get("BundleIdentifier") == "com.local.illucet" for item in descriptors):
        issues.append("shortcut is not bound to the app bundle")
    if not (root / "IllucetApp.xcodeproj/project.pbxproj").is_file():
        issues.append("canonical Xcode project is missing")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--forbid", action="append", default=[], help="Retired product name to reject, case-insensitively")
    parser.add_argument("--bundle", type=Path, help="Additionally inspect a built app or dependency package")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).split(b"\0")
    paths = [root / name.decode() for name in names if name]
    issues = verify_identity(root) + retired_references(paths, root, args.forbid)
    if args.bundle:
        bundle = args.bundle.resolve()
        issues += retired_references(list(bundle.rglob("*")), bundle, args.forbid)
    for issue in issues:
        print(issue)
    if issues:
        return 1
    print("Branding verification passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
