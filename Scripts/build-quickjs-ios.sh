#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../Config/Dependencies.sh
source "${REPOSITORY_ROOT}/Config/Dependencies.sh"

DEVELOPER_DIR="$("${SCRIPT_DIR}/resolve-developer-dir.sh")"
export DEVELOPER_DIR

ARCHIVE="${REPOSITORY_ROOT}/Vendor/Downloads/${QUICKJS_ARCHIVE}"
EXPECTED_ARCHIVE_HASH="${QUICKJS_SHA256}"
NATIVE_WORKSPACE="${ILLUCET_NATIVE_WORKSPACE:-/private/tmp/IllucetNativeBuild}"
[[ "${NATIVE_WORKSPACE}" = /* ]] || { echo 'Use an absolute native workspace.' >&2; exit 2; }
BUILD_ROOT="${NATIVE_WORKSPACE}/Build/QuickJS-${QUICKJS_VERSION}"
FRAMEWORK_ROOT="${REPOSITORY_ROOT}/Vendor/Frameworks"
DESTINATION="${FRAMEWORK_ROOT}/QuickJS.xcframework"
MINIMUM_IOS_VERSION="26.0"

if [[ ! -f "${ARCHIVE}" ]]; then
    echo "Missing ${ARCHIVE}; run Scripts/fetch-stage0-dependencies.sh first." >&2
    exit 1
fi

ACTUAL_ARCHIVE_HASH="$(shasum -a 256 "${ARCHIVE}" | awk '{print $1}')"
if [[ "${ACTUAL_ARCHIVE_HASH}" != "${EXPECTED_ARCHIVE_HASH}" ]]; then
    echo "QuickJS archive SHA-256 mismatch." >&2
    echo "expected: ${EXPECTED_ARCHIVE_HASH}" >&2
    echo "actual:   ${ACTUAL_ARCHIVE_HASH}" >&2
    exit 1
fi

mkdir -p "${BUILD_ROOT}" "${FRAMEWORK_ROOT}"
STAGING="$(mktemp -d "${BUILD_ROOT}/staging.XXXXXX")"
NEW_DESTINATION=""
BACKUP_DESTINATION=""
cleanup() {
    rm -rf "${STAGING}"
    if [[ -n "${NEW_DESTINATION}" && -d "${NEW_DESTINATION}" ]]; then
        rm -rf "${NEW_DESTINATION}"
    fi
    if [[ -n "${BACKUP_DESTINATION}" &&
          -d "${BACKUP_DESTINATION}" &&
          ! -e "${DESTINATION}" ]]; then
        mv "${BACKUP_DESTINATION}" "${DESTINATION}"
    fi
}
trap cleanup EXIT

EXPECTED_ARCHIVE_MEMBERS=$'quickjs-amalgam.c\nquickjs.h\nquickjs-libc.h'
ACTUAL_ARCHIVE_MEMBERS="$(unzip -Z1 "${ARCHIVE}")"
if [[ "${ACTUAL_ARCHIVE_MEMBERS}" != "${EXPECTED_ARCHIVE_MEMBERS}" ]]; then
    echo "QuickJS archive member allowlist mismatch; refusing extraction." >&2
    echo "Expected exactly:" >&2
    echo "${EXPECTED_ARCHIVE_MEMBERS}" >&2
    echo "Found:" >&2
    echo "${ACTUAL_ARCHIVE_MEMBERS}" >&2
    exit 1
fi

unzip -q "${ARCHIVE}" -d "${STAGING}/source"
SOURCE="${STAGING}/source/quickjs-amalgam.c"
HEADERS="${STAGING}/headers"
mkdir -p "${HEADERS}"
cp "${STAGING}/source/quickjs.h" "${HEADERS}/quickjs.h"
cp \
    "${REPOSITORY_ROOT}/Native/JavaScriptBridge/QuickJS.modulemap" \
    "${HEADERS}/module.modulemap"

COMMON_FLAGS=(
    -std=c11
    -O2
    -fPIC
    -fno-common
    -fvisibility=hidden
    -DNDEBUG
    -DQUICKJS_NG_BUILD
    "-DCONFIG_VERSION=\"${QUICKJS_VERSION}\""
    -I"${HEADERS}"
)

compile_arch() {
    local sdk="$1"
    local arch="$2"
    local deployment_flag="$3"
    local output_directory="${STAGING}/${sdk}-${arch}"
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    mkdir -p "${output_directory}"

    xcrun --sdk "${sdk}" clang \
        "${COMMON_FLAGS[@]}" \
        -arch "${arch}" \
        -isysroot "${sdk_path}" \
        "${deployment_flag}" \
        -c "${SOURCE}" \
        -o "${output_directory}/quickjs.o"

    ZERO_AR_DATE=1 xcrun --sdk "${sdk}" libtool \
        -static \
        -o "${output_directory}/libQuickJS.a" \
        "${output_directory}/quickjs.o"
}

compile_arch iphoneos arm64 "-miphoneos-version-min=${MINIMUM_IOS_VERSION}"
compile_arch iphonesimulator arm64 "-mios-simulator-version-min=${MINIMUM_IOS_VERSION}"
compile_arch iphonesimulator x86_64 "-mios-simulator-version-min=${MINIMUM_IOS_VERSION}"

ZERO_AR_DATE=1 xcrun lipo -create \
    "${STAGING}/iphonesimulator-arm64/libQuickJS.a" \
    "${STAGING}/iphonesimulator-x86_64/libQuickJS.a" \
    -output "${STAGING}/libQuickJS.a"

NEW_DESTINATION="${FRAMEWORK_ROOT}/QuickJS.new.$$.xcframework"
xcodebuild -create-xcframework \
    -library "${STAGING}/iphoneos-arm64/libQuickJS.a" \
    -headers "${HEADERS}" \
    -library "${STAGING}/libQuickJS.a" \
    -headers "${HEADERS}" \
    -output "${NEW_DESTINATION}"

DEVICE_ARCHITECTURES="$(xcrun lipo -archs \
    "${NEW_DESTINATION}/ios-arm64/libQuickJS.a")"
SIMULATOR_ARCHITECTURES="$(xcrun lipo -archs \
    "${NEW_DESTINATION}/ios-arm64_x86_64-simulator/libQuickJS.a")"

if [[ "${DEVICE_ARCHITECTURES}" != "arm64" ]]; then
    echo "Unexpected QuickJS device architectures: ${DEVICE_ARCHITECTURES}" >&2
    exit 1
fi
if [[ "${SIMULATOR_ARCHITECTURES}" != "x86_64 arm64" &&
      "${SIMULATOR_ARCHITECTURES}" != "arm64 x86_64" ]]; then
    echo "Unexpected QuickJS simulator architectures: ${SIMULATOR_ARCHITECTURES}" >&2
    exit 1
fi

if [[ -d "${DESTINATION}" ]]; then
    BACKUP_DESTINATION="${DESTINATION}.previous.$(date +%Y%m%d%H%M%S).$$"
    mv "${DESTINATION}" "${BACKUP_DESTINATION}"
fi
if ! mv "${NEW_DESTINATION}" "${DESTINATION}"; then
    if [[ -n "${BACKUP_DESTINATION}" &&
          -d "${BACKUP_DESTINATION}" &&
          ! -e "${DESTINATION}" ]]; then
        mv "${BACKUP_DESTINATION}" "${DESTINATION}"
    fi
    exit 1
fi
NEW_DESTINATION=""

echo "QuickJS-ng ${QUICKJS_VERSION} XCFramework created."
echo "Device architectures: ${DEVICE_ARCHITECTURES}"
echo "Simulator architectures: ${SIMULATOR_ARCHITECTURES}"
