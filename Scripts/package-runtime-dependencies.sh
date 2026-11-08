#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:?provide an absolute output directory}"
[[ "$OUTPUT" = /* ]] || { echo 'Use an absolute output directory.' >&2; exit 2; }
ARCHIVE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["archive"])' "$ROOT/Config/RuntimeRelease.json")"
for runtime in Python QuickJS IllucetMedia; do
    test -f "$ROOT/Vendor/Frameworks/$runtime.xcframework/Info.plist"
done
python3 "$ROOT/Scripts/prune-python-runtime.py" "$ROOT/Vendor/Frameworks/Python.xcframework"
python3 "$ROOT/Scripts/sanitize-python-package-metadata.py" "$ROOT/Vendor/PythonPackages"
python3 "$ROOT/Scripts/verify-python-package-bundle.py" --config "$ROOT/Config/Dependencies.sh" "$ROOT/Vendor/PythonPackages"
mkdir -p "$OUTPUT"
test ! -e "$OUTPUT/$ARCHIVE"
cd "$ROOT"
COPYFILE_DISABLE=1 zip -q -r -X "$OUTPUT/$ARCHIVE" \
    Vendor/Frameworks/Python.xcframework Vendor/Frameworks/QuickJS.xcframework \
    Vendor/Frameworks/IllucetMedia.xcframework Vendor/PythonPackages \
    -x '*/__pycache__/*' '*.pyc' '*/.DS_Store'
python3 "$ROOT/Scripts/verify-public-package.py" "$OUTPUT/$ARCHIVE"
cd "$OUTPUT"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
shasum -a 256 -c "$ARCHIVE.sha256"
