"""Expected package versions selected by the native verified generation store."""

import json
from pathlib import Path
import sys

from illucet_dependency_versions import YTDLP_VERSION, YTDLP_EJS_VERSION, QUICKJS_VERSION


def expected_versions() -> tuple[str, str, str]:
    root = getattr(sys, "_illucet_package_root", None)
    if root is None:
        return YTDLP_VERSION, YTDLP_EJS_VERSION, QUICKJS_VERSION
    path = Path(root) / "_illucet_runtime.json"
    if not path.exists():
        return YTDLP_VERSION, YTDLP_EJS_VERSION, QUICKJS_VERSION
    if path.is_symlink() or path.stat().st_size > 4096:
        raise ValueError("Invalid active package contract")
    contract = json.loads(path.read_text(encoding="utf-8"))
    if (contract.get("schemaVersion") != 1 or contract.get("quickJS") != QUICKJS_VERSION
        or not all(isinstance(contract.get(key), str) and contract[key] for key in ("ytDLP", "ejs", "certifi"))):
        raise ValueError("Incompatible active package contract")
    return contract["ytDLP"], contract["ejs"], QUICKJS_VERSION
