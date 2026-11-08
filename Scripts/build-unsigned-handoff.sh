#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEVELOPER_DIR="$("${SCRIPT_DIR}/resolve-developer-dir.sh")"
export DEVELOPER_DIR

BUILD_STAMP="${ILLUCET_BUILD_STAMP:-$(date '+%Y-%m-%d-%H%M%S')}"
OUTPUT_DIR="${1:-${PROJECT_DIR}/Artifacts/UnsignedBuild/${BUILD_STAMP}}"
DEVICE_DERIVED_DATA="${ILLUCET_DEVICE_DERIVED_DATA:-/private/tmp/IllucetUnsignedDevice-${BUILD_STAMP}}"
SIMULATOR_DERIVED_DATA="${ILLUCET_SIMULATOR_DERIVED_DATA:-/private/tmp/IllucetUnsignedSimulator-${BUILD_STAMP}}"

mkdir -p "${OUTPUT_DIR}"

DEVICE_LOG="${OUTPUT_DIR}/BuildLog.txt"
SIMULATOR_LOG="${OUTPUT_DIR}/SimulatorBuildLog.txt"

env DEVELOPER_DIR="${DEVELOPER_DIR}" \
    xcodebuild \
    -project "${PROJECT_DIR}/IllucetApp.xcodeproj" \
    -scheme Illucet \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "${DEVICE_DERIVED_DATA}" \
    DEVELOPMENT_TEAM='' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' \
    build 2>&1 | tee "${DEVICE_LOG}"

DEVICE_APP="${DEVICE_DERIVED_DATA}/Build/Products/Release-iphoneos/Illucet.app"
if [[ ! -x "${DEVICE_APP}/Illucet" ]]; then
    echo "Expected device application was not produced at ${DEVICE_APP}" >&2
    exit 1
fi

if codesign -dv "${DEVICE_APP}" >/dev/null 2>&1; then
    echo "Device application was unexpectedly code signed." >&2
    exit 1
fi

env DEVELOPER_DIR="${DEVELOPER_DIR}" \
    xcodebuild \
    -project "${PROJECT_DIR}/IllucetApp.xcodeproj" \
    -scheme Illucet \
    -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${SIMULATOR_DERIVED_DATA}" \
    DEVELOPMENT_TEAM='' \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    build 2>&1 | tee "${SIMULATOR_LOG}"

SIMULATOR_APP="${SIMULATOR_DERIVED_DATA}/Build/Products/Release-iphonesimulator/Illucet.app"
if [[ ! -x "${SIMULATOR_APP}/Illucet" ]]; then
    echo "Expected simulator application was not produced at ${SIMULATOR_APP}" >&2
    exit 1
fi

/bin/rm -rf -- "${OUTPUT_DIR}/Illucet.app" "${OUTPUT_DIR}/IllucetApp.xcodeproj"
/usr/bin/ditto "${DEVICE_APP}" "${OUTPUT_DIR}/Illucet.app"
/usr/bin/ditto "${PROJECT_DIR}/IllucetApp.xcodeproj" "${OUTPUT_DIR}/IllucetApp.xcodeproj"

PACKAGE_ROOT="$(mktemp -d /private/tmp/IllucetPayload.XXXXXX)"
cleanup() {
    /bin/rm -rf -- "${PACKAGE_ROOT}"
}
trap cleanup EXIT

mkdir -p "${PACKAGE_ROOT}/Payload"
/usr/bin/ditto "${DEVICE_APP}" "${PACKAGE_ROOT}/Payload/Illucet.app"
(
    cd "${PACKAGE_ROOT}"
    /usr/bin/zip -Xqry "${PACKAGE_ROOT}/Illucet.ipa" Payload
)
/bin/mv -f "${PACKAGE_ROOT}/Illucet.ipa" "${OUTPUT_DIR}/Illucet.ipa"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "${SIMULATOR_APP}" \
    "${OUTPUT_DIR}/Illucet-Simulator.app.zip"

cp "${PROJECT_DIR}/docs/Signing.md" "${OUTPUT_DIR}/Signing.md"
cp "${PROJECT_DIR}/docs/KnownLimitations.md" "${OUTPUT_DIR}/KnownLimitations.md"
cp "${PROJECT_DIR}/docs/ThirdPartyNotices.txt" "${OUTPUT_DIR}/ThirdPartyNotices.txt"
cp "${PROJECT_DIR}/LICENSE" "${OUTPUT_DIR}/LICENSE"
python3 "${PROJECT_DIR}/Scripts/verify-public-package.py" "${OUTPUT_DIR}/Illucet.ipa"

(
    cd "${OUTPUT_DIR}"
    /usr/bin/shasum -a 256 \
        Illucet.ipa \
        ThirdPartyNotices.txt \
        > SHA256SUMS.txt
)

printf 'Unsigned handoff created at %s\n' "${OUTPUT_DIR}"
