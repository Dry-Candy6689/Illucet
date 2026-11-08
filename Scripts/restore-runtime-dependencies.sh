#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOSITORY="${ILLUCET_RUNTIME_REPOSITORY:-${GITHUB_REPOSITORY:-Dry-Candy6689/Illucet}}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/illucet-runtimes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
read_runtime_value() {
    python3 - "$ROOT/Config/RuntimeRelease.json" "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])
PY
}
TAG="$(read_runtime_value tag)"
ARCHIVE="$(read_runtime_value archive)"
gh release download "$TAG" --repo "$REPOSITORY" --pattern "$ARCHIVE" --dir "$WORK"
python3 "$ROOT/Scripts/restore-runtime-dependencies.py" "$WORK/$ARCHIVE" "$ROOT"
