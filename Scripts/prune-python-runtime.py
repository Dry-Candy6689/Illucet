#!/usr/bin/env python3
"""Omit CPython's own test suite and test keys from a generated runtime payload."""
from pathlib import Path
import shutil
import sys


def prune(root: Path) -> int:
    root = root.resolve(strict=True)
    count = 0
    for library in root.rglob("python3.*"):
        if not library.is_dir() or not library.resolve().is_relative_to(root):
            continue
        # The app installs verified extractor generations itself; pip is unused.
        # GUI-library test suites also carry upstream sample home paths/test keys.
        for relative in ("test", "ensurepip", "idlelib/idle_test", "tkinter/test", "ctypes/test", "sqlite3/test", "unittest/test"):
            test = library / relative
            if test.is_symlink():
                raise ValueError("unexpected linked standard-library test directory")
            if test.is_dir():
                shutil.rmtree(test)
                count += 1
    return count


if __name__ == "__main__":
    print(f"Removed {prune(Path(sys.argv[1]))} upstream standard-library test directories.")
