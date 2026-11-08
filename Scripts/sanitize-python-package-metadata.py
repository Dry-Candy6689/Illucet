#!/usr/bin/env python3
"""Remove optional pip metadata that exposes local wheel installation paths."""
import csv
import io
import sys
from pathlib import Path


def sanitize(root: Path) -> int:
    if not root.is_dir():
        raise ValueError("Python package directory is missing")
    count = 0
    for metadata in root.glob("*.dist-info/direct_url.json"):
        if metadata.is_symlink():
            raise ValueError("Package metadata must be a regular file")
        record = metadata.parent / "RECORD"
        if record.exists():
            rows = list(csv.reader(io.StringIO(record.read_text())))
            output = io.StringIO(newline="")
            csv.writer(output).writerows(row for row in rows if row and row[0] != str(metadata.relative_to(root)))
            record.write_text(output.getvalue())
        metadata.unlink()
        count += 1
    return count


if __name__ == "__main__":
    print(f"Removed {sanitize(Path(sys.argv[1]))} local installation metadata file(s).")
