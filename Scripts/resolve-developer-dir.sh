#!/bin/bash

set -euo pipefail

if [[ -n "${DEVELOPER_DIR:-}" ]] &&
    [[ -x "${DEVELOPER_DIR}/usr/bin/xcodebuild" ]]; then
    printf '%s\n' "${DEVELOPER_DIR}"
    exit 0
fi

SELECTED="$(xcode-select -p 2>/dev/null || true)"
if [[ -x "${SELECTED}/usr/bin/xcodebuild" ]]; then
    printf '%s\n' "${SELECTED}"
    exit 0
fi

for candidate in \
    /Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode-beta.app/Contents/Developer; do
    if [[ -x "${candidate}/usr/bin/xcodebuild" ]]; then
        printf '%s\n' "${candidate}"
        exit 0
    fi
done

echo "A complete Xcode installation could not be found." >&2
exit 1
