#!/usr/bin/env python3
"""Check required entry documentation and local Markdown link targets."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


REQUIRED_FILES = (
    "AGENTS.md",
    "README.md",
    "LICENSE",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "docs/Signing.md",
    "docs/ThirdPartyNotices.txt",
    "docs/Development.md",
    "docs/Architecture.md",
    "docs/KnownLimitations.md",
)
LINK = re.compile(r"!?\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+[^)]*)?\)")


def verify(root: Path) -> list[str]:
    """Return actionable structural and Markdown-link issues under root."""
    root = root.resolve()
    issues: list[str] = []
    for name in REQUIRED_FILES:
        path = root / name
        if not path.is_file():
            issues.append(f"required file is missing: {name}")

    markdown_files = [root / name for name in ("AGENTS.md", "README.md", "CONTRIBUTING.md", "SECURITY.md")]
    markdown_files.extend(sorted((root / "docs").rglob("*.md")))
    for source in markdown_files:
        try:
            content = source.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            issues.append(f"cannot read Markdown file {source.relative_to(root)}: {error}")
            continue
        for match in LINK.finditer(content):
            target = (match.group(1) or match.group(2) or "").strip()
            parsed = urlsplit(target)
            if not parsed.path or parsed.scheme or parsed.netloc:
                continue  # URLs and fragment-only links are external to this check.
            relative = Path(unquote(parsed.path))
            candidate = (source.parent / relative).resolve()
            try:
                candidate.relative_to(root)
            except ValueError:
                line = content.count("\n", 0, match.start()) + 1
                issues.append(f"link escapes repository at {source.relative_to(root)}:{line}: {target}")
                continue
            if not candidate.exists():
                line = content.count("\n", 0, match.start()) + 1
                issues.append(f"broken local link at {source.relative_to(root)}:{line}: {target}")

    return issues


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    issues = verify(root)
    if issues:
        print("Project-state verification failed:", file=sys.stderr)
        for issue in issues:
            print(f"- {issue}", file=sys.stderr)
        return 1
    print("Project-state verification passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
