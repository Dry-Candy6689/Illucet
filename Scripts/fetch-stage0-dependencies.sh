#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../Config/Dependencies.sh
source "${REPOSITORY_ROOT}/Config/Dependencies.sh"

DOWNLOAD_DIR="${REPOSITORY_ROOT}/Vendor/Downloads"
PYTHON_PACKAGE_DIR="${REPOSITORY_ROOT}/Vendor/PythonPackages"
FETCH_MODE="all"

if [[ "${1:-}" == "--python-packages-only" && "$#" -eq 1 ]]; then
    FETCH_MODE="python-packages-only"
elif [[ "$#" -ne 0 ]]; then
    echo "Usage: $0 [--python-packages-only]" >&2
    exit 64
fi

mkdir -p "${DOWNLOAD_DIR}" "${PYTHON_PACKAGE_DIR}"

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(sha256_of "${file}")"

    if [[ "${actual}" != "${expected}" ]]; then
        echo "SHA-256 mismatch for ${file}" >&2
        echo "expected: ${expected}" >&2
        echo "actual:   ${actual}" >&2
        return 1
    fi
}

fetch_https() {
    local url="$1"
    local destination="$2"
    local expected_sha256="$3"
    local partial="${destination}.partial.$$"

    if [[ -f "${destination}" ]]; then
        if verify_sha256 "${destination}" "${expected_sha256}"; then
            echo "Verified cached $(basename "${destination}")"
            return
        fi

        local rejected="${destination}.invalid.$(date +%Y%m%d%H%M%S)"
        mv "${destination}" "${rejected}"
        echo "Moved invalid cached file to ${rejected}" >&2
    fi

    curl --fail --location --proto '=https' "${url}" --output "${partial}"
    verify_sha256 "${partial}" "${expected_sha256}"
    mv "${partial}" "${destination}"
    echo "Downloaded and verified $(basename "${destination}")"
}

fetch_pypi_wheel() {
    local requirement="$1"
    local filename="$2"
    local expected_sha256="$3"
    local destination="${DOWNLOAD_DIR}/${filename}"

    if [[ ! -f "${destination}" ]]; then
        python3 -m pip download \
            --isolated \
            --disable-pip-version-check \
            --index-url https://pypi.org/simple \
            --only-binary=:all: \
            --no-deps \
            --dest "${DOWNLOAD_DIR}" \
            "${requirement}"
    fi

    verify_sha256 "${destination}" "${expected_sha256}"
    echo "Verified ${filename}"
}

if [[ "${FETCH_MODE}" == "all" ]]; then
    fetch_https \
        "${CPYTHON_URL}" \
        "${DOWNLOAD_DIR}/${CPYTHON_ARCHIVE}" \
        "${CPYTHON_SHA256}"
fi

fetch_pypi_wheel \
    "yt-dlp==${YTDLP_PACKAGE_VERSION:-${YTDLP_VERSION}}" \
    "${YTDLP_WHEEL}" \
    "${YTDLP_SHA256}"

fetch_pypi_wheel \
    "yt-dlp-ejs==${YTDLP_EJS_VERSION}" \
    "${YTDLP_EJS_WHEEL}" \
    "${YTDLP_EJS_SHA256}"

fetch_pypi_wheel \
    "certifi==${CERTIFI_VERSION}" \
    "${CERTIFI_WHEEL}" \
    "${CERTIFI_SHA256}"

if [[ "${FETCH_MODE}" == "all" ]]; then
    fetch_https \
        "${QUICKJS_URL}" \
        "${DOWNLOAD_DIR}/${QUICKJS_ARCHIVE}" \
        "${QUICKJS_SHA256}"

    fetch_https \
        "${FFMPEG_URL}" \
        "${DOWNLOAD_DIR}/${FFMPEG_ARCHIVE}" \
        "${FFMPEG_SHA256}"

    fetch_https \
        "${LAME_URL}" \
        "${DOWNLOAD_DIR}/${LAME_ARCHIVE}" \
        "${LAME_SHA256}"

    FFMPEG_SIGNATURE="${DOWNLOAD_DIR}/${FFMPEG_ARCHIVE}.asc"
    FFMPEG_PUBLIC_KEY="${DOWNLOAD_DIR}/ffmpeg-devel.asc"
    FFMPEG_GPG_HOME="${DOWNLOAD_DIR}/ffmpeg-gpg-home"
    mkdir -p "${FFMPEG_GPG_HOME}"
    chmod 700 "${FFMPEG_GPG_HOME}"
    curl --fail --location --proto '=https' \
        "${FFMPEG_SIGNATURE_URL}" \
        --output "${FFMPEG_SIGNATURE}"
    curl --fail --location --proto '=https' \
        "${FFMPEG_KEY_URL}" \
        --output "${FFMPEG_PUBLIC_KEY}"

    DETECTED_FINGERPRINT="$(
        gpg --homedir "${FFMPEG_GPG_HOME}" \
            --show-keys --with-colons "${FFMPEG_PUBLIC_KEY}" |
            awk -F: '$1 == "fpr" { print $10; exit }'
    )"
    if [[ "${DETECTED_FINGERPRINT}" != "${FFMPEG_SIGNING_FINGERPRINT}" ]]; then
        echo "Unexpected FFmpeg signing key fingerprint" >&2
        echo "expected: ${FFMPEG_SIGNING_FINGERPRINT}" >&2
        echo "actual:   ${DETECTED_FINGERPRINT}" >&2
        exit 1
    fi

    FFMPEG_KEYRING="${DOWNLOAD_DIR}/ffmpeg-release-keyring.gpg"
    gpg --homedir "${FFMPEG_GPG_HOME}" \
        --batch --yes --dearmor \
        --output "${FFMPEG_KEYRING}" \
        "${FFMPEG_PUBLIC_KEY}"
    gpgv \
        --keyring "${FFMPEG_KEYRING}" \
        "${FFMPEG_SIGNATURE}" \
        "${DOWNLOAD_DIR}/${FFMPEG_ARCHIVE}"
fi

PYTHON_PACKAGE_STAGING="${PYTHON_PACKAGE_DIR}.staging.$$"
mkdir -p "${PYTHON_PACKAGE_STAGING}"
python3 -m pip install \
    --isolated \
    --disable-pip-version-check \
    --no-compile \
    --no-deps \
    --target "${PYTHON_PACKAGE_STAGING}" \
    "${DOWNLOAD_DIR}/${YTDLP_WHEEL}" \
    "${DOWNLOAD_DIR}/${YTDLP_EJS_WHEEL}" \
    "${DOWNLOAD_DIR}/${CERTIFI_WHEEL}"

python3 "${REPOSITORY_ROOT}/Scripts/sanitize-python-package-metadata.py" "${PYTHON_PACKAGE_STAGING}"

if [[ -d "${PYTHON_PACKAGE_STAGING}/bin" ]]; then
    mv \
        "${PYTHON_PACKAGE_STAGING}/bin" \
        "${DOWNLOAD_DIR}/python-entrypoints.not-bundled.$$"
fi

if find "${PYTHON_PACKAGE_STAGING}" \
    \( -name '*.so' -o -name '*.dylib' -o -name '*.fwork' \) \
    -print -quit | grep -q .; then
    echo "A Python wheel unexpectedly contained native executable code." >&2
    exit 1
fi

if [[ -d "${PYTHON_PACKAGE_DIR}" ]]; then
    if [[ -d "${PYTHON_PACKAGE_DIR}.previous" ]]; then
        mv \
            "${PYTHON_PACKAGE_DIR}.previous" \
            "${PYTHON_PACKAGE_DIR}.previous.$(date +%Y%m%d%H%M%S)"
    fi
    mv "${PYTHON_PACKAGE_DIR}" "${PYTHON_PACKAGE_DIR}.previous"
fi
mv "${PYTHON_PACKAGE_STAGING}" "${PYTHON_PACKAGE_DIR}"

python3 "${REPOSITORY_ROOT}/Scripts/verify-python-package-bundle.py" \
    --config "${REPOSITORY_ROOT}/Config/Dependencies.sh" \
    "${PYTHON_PACKAGE_DIR}"

if [[ "${FETCH_MODE}" == "all" ]]; then
    echo "All Stage 0 source archives and Python packages are verified."
else
    echo "All Stage 0 Python packages are verified."
fi
