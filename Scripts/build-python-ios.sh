#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../Config/Dependencies.sh
source "${REPOSITORY_ROOT}/Config/Dependencies.sh"

export DEVELOPER_DIR="$(
    "${SCRIPT_DIR}/resolve-developer-dir.sh"
)"

ARCHIVE="${REPOSITORY_ROOT}/Vendor/Downloads/${CPYTHON_ARCHIVE}"
NATIVE_WORKSPACE="${ILLUCET_NATIVE_WORKSPACE:-/private/tmp/IllucetNativeBuild}"
[[ "${NATIVE_WORKSPACE}" = /* ]] || { echo 'Use an absolute native workspace.' >&2; exit 2; }
SOURCE_PARENT="${NATIVE_WORKSPACE}/Source"
SOURCE_ROOT="${SOURCE_PARENT}/Python-${CPYTHON_VERSION}"
BUILD_ROOT="${NATIVE_WORKSPACE}/Build/Python-${CPYTHON_VERSION}"
FRAMEWORK_ROOT="${REPOSITORY_ROOT}/Vendor/Frameworks"
LOG_ROOT="${NATIVE_WORKSPACE}/Logs"
LOG_FILE="${LOG_ROOT}/python-ios-$(date +%Y%m%d-%H%M%S).log"

mkdir -p \
    "${SOURCE_PARENT}" \
    "${BUILD_ROOT}" \
    "${FRAMEWORK_ROOT}" \
    "${LOG_ROOT}"

ACTUAL_SHA256="$(shasum -a 256 "${ARCHIVE}" | awk '{print $1}')"
if [[ "${ACTUAL_SHA256}" != "${CPYTHON_SHA256}" ]]; then
    echo "CPython archive is absent or failed SHA-256 verification." >&2
    echo "Run ./Scripts/fetch-stage0-dependencies.sh first." >&2
    exit 1
fi

if [[ ! -x "${SOURCE_ROOT}/Platforms/Apple" ]]; then
    STAGING="${SOURCE_PARENT}/.Python-${CPYTHON_VERSION}.staging.$$"
    mkdir -p "${STAGING}"
    tar -xf "${ARCHIVE}" -C "${STAGING}" --strip-components 1
    mv "${STAGING}" "${SOURCE_ROOT}"
fi

echo "Building CPython ${CPYTHON_VERSION} for iOS with ${DEVELOPER_DIR}"
echo "Full log: ${LOG_FILE}"

find_dist_archive() {
    if [[ ! -d "${SOURCE_ROOT}/cross-build/dist" ]]; then
        return 0
    fi

    find "${SOURCE_ROOT}/cross-build/dist" \
        -maxdepth 1 \
        -type f \
        \( \
            -name 'python-*-iOS-XCframework.tar.gz' \
            -o -name 'Python-*-iOS-support.*.tar.gz' \
        \) \
        -print |
        sort |
        tail -n 1
}

DIST_ARCHIVE="$(find_dist_archive)"

if [[ -z "${DIST_ARCHIVE}" ]]; then
    if [[ -d "${SOURCE_ROOT}/cross-build" ]]; then
        INCOMPLETE_BUILD="${BUILD_ROOT}/cross-build.incomplete.$(date +%Y%m%d%H%M%S)"
        mv "${SOURCE_ROOT}/cross-build" "${INCOMPLETE_BUILD}"
        echo "Preserved incomplete CPython build at ${INCOMPLETE_BUILD}"
        echo "Restarting the upstream iOS build from a clean generated tree."
    fi

    (
        cd "${SOURCE_ROOT}"
        python3 Platforms/Apple build iOS
    ) 2>&1 | tee "${LOG_FILE}"

    DIST_ARCHIVE="$(find_dist_archive)"
else
    echo "Reusing existing CPython iOS archive: ${DIST_ARCHIVE}" |
        tee "${LOG_FILE}"
fi

if [[ -z "${DIST_ARCHIVE}" ]]; then
    echo "CPython build completed without the expected iOS support archive." >&2
    exit 1
fi

python3 - "${SOURCE_ROOT}/cross-build/downloads" "${REPOSITORY_ROOT}/Vendor/PythonSourceDeps.sha256" <<'PY'
import hashlib, pathlib, sys
cache, manifest = map(pathlib.Path, sys.argv[1:])
for line in manifest.read_text().splitlines():
    expected, name = line.split()
    with (cache / name).open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != expected:
            raise SystemExit("Python support-package SHA-256 verification failed")
print("Python support-package digests verified.")
PY

PACKAGE_DIR="${BUILD_ROOT}/support-package"
if [[ -d "${PACKAGE_DIR}" ]]; then
    mv "${PACKAGE_DIR}" "${PACKAGE_DIR}.previous.$(date +%Y%m%d%H%M%S)"
fi
mkdir -p "${PACKAGE_DIR}"
tar -xzf "${DIST_ARCHIVE}" -C "${PACKAGE_DIR}"

BUILT_FRAMEWORK="$(
    find "${PACKAGE_DIR}" \
        -type d \
        -name Python.xcframework \
        -print \
        -quit
)"
if [[ -z "${BUILT_FRAMEWORK}" ]]; then
    echo "The iOS support archive did not contain Python.xcframework." >&2
    exit 1
fi

DESTINATION="${FRAMEWORK_ROOT}/Python.xcframework"
if [[ -d "${DESTINATION}" ]]; then
    mv "${DESTINATION}" "${DESTINATION}.previous.$(date +%Y%m%d%H%M%S)"
fi
ditto "${BUILT_FRAMEWORK}" "${DESTINATION}"

PATCH_FILE="${REPOSITORY_ROOT}/Patches/cpython-3.14-ios-codesign-xattrs.patch"
if patch --dry-run --forward --silent -p1 -d "${DESTINATION}" \
    < "${PATCH_FILE}"; then
    patch --forward --silent -p1 -d "${DESTINATION}" < "${PATCH_FILE}"
elif ! patch --dry-run --reverse --silent -p1 -d "${DESTINATION}" \
    < "${PATCH_FILE}"; then
    echo "Could not apply or recognize the CPython packaging patch." >&2
    exit 1
fi

cp "${DIST_ARCHIVE}" "${BUILD_ROOT}/"
python3 "${SCRIPT_DIR}/prune-python-runtime.py" "${DESTINATION}"

echo "Created ${DESTINATION}"
echo "CPython build log: ${LOG_FILE}"
