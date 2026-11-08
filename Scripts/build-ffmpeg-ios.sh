#!/bin/bash

set -euo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../Config/Dependencies.sh
source "${REPOSITORY_ROOT}/Config/Dependencies.sh"

DEVELOPER_DIR="$("${SCRIPT_DIR}/resolve-developer-dir.sh")"
export DEVELOPER_DIR
export ZERO_AR_DATE=1

MINIMUM_IOS_VERSION="26.0"
FFMPEG_ARCHIVE_PATH="${REPOSITORY_ROOT}/Vendor/Downloads/${FFMPEG_ARCHIVE}"
FFMPEG_SIGNATURE_PATH="${FFMPEG_ARCHIVE_PATH}.asc"
FFMPEG_PUBLIC_KEY_PATH="${REPOSITORY_ROOT}/Vendor/Downloads/ffmpeg-devel.asc"
FFMPEG_KEYRING_PATH="${REPOSITORY_ROOT}/Vendor/Downloads/ffmpeg-release-keyring.gpg"
FFMPEG_GPG_HOME="${REPOSITORY_ROOT}/Vendor/Downloads/ffmpeg-gpg-home"
LAME_ARCHIVE_PATH="${REPOSITORY_ROOT}/Vendor/Downloads/${LAME_ARCHIVE}"
NATIVE_WORKSPACE="${ILLUCET_NATIVE_WORKSPACE:-/private/tmp/IllucetNativeBuild}"
[[ "${NATIVE_WORKSPACE}" = /* ]] || { echo 'Use an absolute native workspace.' >&2; exit 2; }
BUILD_ROOT="${NATIVE_WORKSPACE}/Build/FFmpeg-${FFMPEG_VERSION}"
FRAMEWORK_ROOT="${REPOSITORY_ROOT}/Vendor/Frameworks"
DESTINATION="${FRAMEWORK_ROOT}/IllucetMedia.xcframework"
MODULE_MAP="${REPOSITORY_ROOT}/Native/FFmpegBridge/FFmpeg.modulemap"

if [[ ! -f "${FFMPEG_ARCHIVE_PATH}" ||
      ! -f "${LAME_ARCHIVE_PATH}" ||
      ! -f "${FFMPEG_SIGNATURE_PATH}" ||
      ! -f "${FFMPEG_PUBLIC_KEY_PATH}" ||
      ! -f "${FFMPEG_KEYRING_PATH}" ]]; then
    echo "Missing verified source material; run Scripts/fetch-stage0-dependencies.sh first." >&2
    exit 1
fi
if [[ ! -f "${MODULE_MAP}" ]]; then
    echo "Missing FFmpeg module map: ${MODULE_MAP}" >&2
    exit 1
fi

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
        exit 1
    fi
}

verify_sha256 "${FFMPEG_ARCHIVE_PATH}" "${FFMPEG_SHA256}"
verify_sha256 "${LAME_ARCHIVE_PATH}" "${LAME_SHA256}"

DETECTED_FINGERPRINT="$(
    gpg --homedir "${FFMPEG_GPG_HOME}" \
        --show-keys --with-colons "${FFMPEG_PUBLIC_KEY_PATH}" |
        awk -F: '$1 == "fpr" { print $10; exit }'
)"
if [[ "${DETECTED_FINGERPRINT}" != "${FFMPEG_SIGNING_FINGERPRINT}" ]]; then
    echo "Unexpected FFmpeg signing key fingerprint." >&2
    echo "expected: ${FFMPEG_SIGNING_FINGERPRINT}" >&2
    echo "actual:   ${DETECTED_FINGERPRINT}" >&2
    exit 1
fi
gpgv \
    --keyring "${FFMPEG_KEYRING_PATH}" \
    "${FFMPEG_SIGNATURE_PATH}" \
    "${FFMPEG_ARCHIVE_PATH}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "${BUILD_ROOT}" "${FRAMEWORK_ROOT}"
LOCK_DIRECTORY="${BUILD_ROOT}/.build-lock"
if ! mkdir "${LOCK_DIRECTORY}"; then
    echo "Another FFmpeg build may be active: ${LOCK_DIRECTORY}" >&2
    echo "If no build is running, remove only that stale lock directory." >&2
    exit 1
fi

# FFmpeg embeds configure arguments and __FILE__ strings. A random build path
# therefore changes otherwise identical archives. Keep the work path stable and
# use an atomic lock to prevent concurrent builds from corrupting it.
STAGING="${BUILD_ROOT}/Work"
STALE_STAGING=""
if [[ -d "${STAGING}" ]]; then
    STALE_STAGING="${BUILD_ROOT}/Work.stale.${RUN_ID}"
    mv "${STAGING}" "${STALE_STAGING}"
fi
mkdir -p "${STAGING}"

LOG_ROOT="${BUILD_ROOT}/Logs/${RUN_ID}"
METADATA_ROOT="${BUILD_ROOT}/Metadata/${RUN_ID}"
NEW_DESTINATION=""
BACKUP_DESTINATION=""
mkdir -p "${LOG_ROOT}" "${METADATA_ROOT}"

cleanup() {
    local status=$?
    if [[ -n "${STAGING}" && -d "${STAGING}" ]]; then
        rm -rf "${STAGING}"
    fi
    if [[ -n "${NEW_DESTINATION}" && -d "${NEW_DESTINATION}" ]]; then
        rm -rf "${NEW_DESTINATION}"
    fi
    if [[ -n "${BACKUP_DESTINATION}" &&
          -d "${BACKUP_DESTINATION}" &&
          ! -e "${DESTINATION}" ]]; then
        mv "${BACKUP_DESTINATION}" "${DESTINATION}"
    fi
    if [[ "${status}" -eq 0 &&
          -n "${STALE_STAGING}" &&
          -d "${STALE_STAGING}" ]]; then
        rm -rf "${STALE_STAGING}"
    fi
    if [[ -d "${LOCK_DIRECTORY}" ]]; then
        rmdir "${LOCK_DIRECTORY}"
    fi
    if [[ "${status}" -ne 0 ]]; then
        echo "FFmpeg build failed. Logs: ${LOG_ROOT}" >&2
        if [[ -n "${STALE_STAGING}" && -d "${STALE_STAGING}" ]]; then
            echo "Prior interrupted work was preserved: ${STALE_STAGING}" >&2
        fi
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

validate_tar_archive() {
    local archive="$1"
    local expected_root="$2"
    local label="$3"
    local members="${METADATA_ROOT}/${label}-archive-members.txt"
    local details="${METADATA_ROOT}/${label}-archive-details.txt"

    LC_ALL=C tar -tf "${archive}" > "${members}"
    LC_ALL=C tar -tvf "${archive}" > "${details}"

    if ! LC_ALL=C awk -v root="${expected_root}/" '
        index($0, root) != 1 ||
        $0 ~ /^\// ||
        $0 ~ /(^|\/)\.\.($|\/)/ ||
        $0 ~ /\\/ ||
        $0 ~ /[[:cntrl:]]/ {
            print "Unsafe or unexpected archive member: " $0 > "/dev/stderr"
            bad = 1
        }
        END { exit bad }
    ' "${members}"; then
        echo "${label} archive path allowlist validation failed." >&2
        exit 1
    fi

    if ! LC_ALL=C awk '
        substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" {
            print "Disallowed archive member type: " $0 > "/dev/stderr"
            bad = 1
        }
        END { exit bad }
    ' "${details}"; then
        echo "${label} archive contains links or special files; refusing extraction." >&2
        exit 1
    fi
}

validate_tar_archive \
    "${FFMPEG_ARCHIVE_PATH}" \
    "ffmpeg-${FFMPEG_VERSION}" \
    "ffmpeg"
validate_tar_archive \
    "${LAME_ARCHIVE_PATH}" \
    "lame-${LAME_VERSION}" \
    "lame"

mkdir -p "${STAGING}/source"
tar -xf "${FFMPEG_ARCHIVE_PATH}" -C "${STAGING}/source"
tar -xf "${LAME_ARCHIVE_PATH}" -C "${STAGING}/source"
FFMPEG_SOURCE="${STAGING}/source/ffmpeg-${FFMPEG_VERSION}"
LAME_SOURCE="${STAGING}/source/lame-${LAME_VERSION}"

if [[ ! -x "${FFMPEG_SOURCE}/configure" ||
      ! -x "${LAME_SOURCE}/configure" ]]; then
    echo "Validated archives did not contain the expected configure scripts." >&2
    exit 1
fi

case "$(uname -m)" in
    arm64) ;;
    *)
        echo "This build script is currently validated only on an arm64 Mac host." >&2
        exit 1
        ;;
esac

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
if [[ -z "${JOBS}" || "${JOBS}" -lt 1 ]]; then
    JOBS=4
fi

CLANG="$(xcrun -f clang)"
AR="$(xcrun -f ar)"
RANLIB="$(xcrun -f ranlib)"
NM="$(xcrun -f nm)"
STRIP="$(xcrun -f strip)"
PKG_CONFIG_BIN="$(command -v pkg-config || command -v pkgconf || true)"
if [[ -z "${PKG_CONFIG_BIN}" ]]; then
    echo "pkg-config/pkgconf is required to validate libmp3lame." >&2
    exit 1
fi

log_command() {
    local file="$1"
    shift
    {
        printf '%q ' "$@"
        printf '\n'
    } >> "${file}"
}

run_logged() {
    local log="$1"
    shift
    log_command "${log}.command" "$@"
    if ! "$@" > "${log}" 2>&1; then
        echo "Command failed: $(cat "${log}.command")" >&2
        tail -n 120 "${log}" >&2
        exit 1
    fi
}

build_lame_slice() {
    local slice="$1"
    local sdk="$2"
    local arch="$3"
    local host="$4"
    local deployment_flag="$5"
    local sdk_path="$6"
    local build_dir="${STAGING}/build/lame-${slice}"
    local install_dir="${STAGING}/install/lame-${slice}"
    local log_prefix="${LOG_ROOT}/lame-${slice}"

    mkdir -p "${build_dir}" "${install_dir}"
    (
        cd "${build_dir}"
        export CC="${CLANG}"
        export AR="${AR}"
        export RANLIB="${RANLIB}"
        export NM="${NM}"
        export STRIP="${STRIP}"
        export CFLAGS="-arch ${arch} -isysroot ${sdk_path} ${deployment_flag} -O2 -fPIC -fno-common"
        export CPPFLAGS="-arch ${arch} -isysroot ${sdk_path} ${deployment_flag}"
        export LDFLAGS="-arch ${arch} -isysroot ${sdk_path} ${deployment_flag}"
        export lt_cv_sys_max_cmd_len=65536

        run_logged "${log_prefix}-configure.log" \
            "${LAME_SOURCE}/configure" \
            "--host=${host}" \
            "--prefix=${install_dir}" \
            --disable-shared \
            --enable-static \
            --disable-frontend \
            --disable-decoder \
            --disable-nasm \
            --disable-dependency-tracking \
            --with-pic
        run_logged "${log_prefix}-make.log" make "-j${JOBS}"
        run_logged "${log_prefix}-install.log" make install
    )

    cp "${build_dir}/config.log" "${METADATA_ROOT}/lame-${slice}-config.log"
    cp "${build_dir}/config.h" "${METADATA_ROOT}/lame-${slice}-config.h"
}

build_ffmpeg_slice() {
    local slice="$1"
    local sdk="$2"
    local arch="$3"
    local ffmpeg_arch="$4"
    local deployment_flag="$5"
    local sdk_path="$6"
    local lame_install="${STAGING}/install/lame-${slice}"
    local build_dir="${STAGING}/build/ffmpeg-${slice}"
    local install_dir="${STAGING}/install/ffmpeg-${slice}"
    local log_prefix="${LOG_ROOT}/ffmpeg-${slice}"
    local extra_cflags="-arch ${arch} -isysroot ${sdk_path} ${deployment_flag} -O2 -fPIC -fno-common -I${lame_install}/include"
    local extra_ldflags="-arch ${arch} -isysroot ${sdk_path} ${deployment_flag} -L${lame_install}/lib"
    local configure_args=(
        "--prefix=${install_dir}"
        --enable-cross-compile
        --target-os=darwin
        "--arch=${ffmpeg_arch}"
        "--cc=${CLANG}"
        "--ar=${AR}"
        "--ranlib=${RANLIB}"
        "--nm=${NM}"
        "--strip=${STRIP}"
        "--sysroot=${sdk_path}"
        "--pkg-config=${PKG_CONFIG_BIN}"
        "--pkg-config-flags=--static"
        "--extra-cflags=${extra_cflags}"
        "--extra-ldflags=${extra_ldflags}"
        --enable-static
        --disable-shared
        --enable-pic
        --disable-programs
        --disable-doc
        --disable-debug
        --disable-avdevice
        --disable-network
        --disable-autodetect
        --enable-avcodec
        --enable-avformat
        --enable-avfilter
        --enable-swscale
        --enable-swresample
        --enable-videotoolbox
        --enable-audiotoolbox
        --enable-libmp3lame
    )

    if [[ "${arch}" == "x86_64" ]]; then
        configure_args+=(--disable-x86asm)
    fi

    mkdir -p "${build_dir}" "${install_dir}"
    (
        cd "${build_dir}"
        export PKG_CONFIG_PATH="${lame_install}/lib/pkgconfig"
        export PKG_CONFIG_LIBDIR="${lame_install}/lib/pkgconfig"
        export PKG_CONFIG_SYSROOT_DIR=""
        run_logged "${log_prefix}-configure.log" \
            "${FFMPEG_SOURCE}/configure" "${configure_args[@]}"
        run_logged "${log_prefix}-make.log" make "-j${JOBS}"
        run_logged "${log_prefix}-install.log" make install
    )

    {
        printf '%q ' "${FFMPEG_SOURCE}/configure" "${configure_args[@]}"
        printf '\n'
    } > "${METADATA_ROOT}/ffmpeg-${slice}-configure-command.txt"
    cp "${build_dir}/config.h" "${METADATA_ROOT}/ffmpeg-${slice}-config.h"
    cp "${build_dir}/config_components.h" \
        "${METADATA_ROOT}/ffmpeg-${slice}-config-components.h"
    cp "${build_dir}/ffbuild/config.log" \
        "${METADATA_ROOT}/ffmpeg-${slice}-config.log"
    cp "${build_dir}/ffbuild/config.mak" \
        "${METADATA_ROOT}/ffmpeg-${slice}-config.mak"
}

DEVICE_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SIMULATOR_SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"

build_lame_slice \
    ios-arm64 iphoneos arm64 arm-apple-darwin \
    "-miphoneos-version-min=${MINIMUM_IOS_VERSION}" \
    "${DEVICE_SDK_PATH}"
build_lame_slice \
    simulator-arm64 iphonesimulator arm64 arm-apple-darwin \
    "-mios-simulator-version-min=${MINIMUM_IOS_VERSION}" \
    "${SIMULATOR_SDK_PATH}"
build_lame_slice \
    simulator-x86_64 iphonesimulator x86_64 x86_64-apple-darwin \
    "-mios-simulator-version-min=${MINIMUM_IOS_VERSION}" \
    "${SIMULATOR_SDK_PATH}"

build_ffmpeg_slice \
    ios-arm64 iphoneos arm64 arm64 \
    "-miphoneos-version-min=${MINIMUM_IOS_VERSION}" \
    "${DEVICE_SDK_PATH}"
build_ffmpeg_slice \
    simulator-arm64 iphonesimulator arm64 arm64 \
    "-mios-simulator-version-min=${MINIMUM_IOS_VERSION}" \
    "${SIMULATOR_SDK_PATH}"
build_ffmpeg_slice \
    simulator-x86_64 iphonesimulator x86_64 x86_64 \
    "-mios-simulator-version-min=${MINIMUM_IOS_VERSION}" \
    "${SIMULATOR_SDK_PATH}"

header_manifest() {
    local include_root="$1"
    (
        cd "${include_root}"
        find . -type f -print |
            LC_ALL=C sort |
            while IFS= read -r file; do
                printf '%s  %s\n' "$(shasum -a 256 "${file}" | awk '{print $1}')" "${file}"
            done
    )
}

for slice in ios-arm64 simulator-arm64 simulator-x86_64; do
    {
        header_manifest "${STAGING}/install/ffmpeg-${slice}/include"
        header_manifest "${STAGING}/install/lame-${slice}/include"
    } > "${METADATA_ROOT}/${slice}-headers.sha256"
done

if ! cmp -s \
    "${METADATA_ROOT}/ios-arm64-headers.sha256" \
    "${METADATA_ROOT}/simulator-arm64-headers.sha256" ||
   ! cmp -s \
    "${METADATA_ROOT}/ios-arm64-headers.sha256" \
    "${METADATA_ROOT}/simulator-x86_64-headers.sha256"; then
    echo "Installed public headers differ between target slices." >&2
    exit 1
fi

COMPONENT_LIBRARIES=(
    libavcodec.a
    libavformat.a
    libavfilter.a
    libavutil.a
    libswscale.a
    libswresample.a
)

combine_slice() {
    local slice="$1"
    local ffmpeg_lib="${STAGING}/install/ffmpeg-${slice}/lib"
    local lame_lib="${STAGING}/install/lame-${slice}/lib/libmp3lame.a"
    local output_dir="${STAGING}/combined/${slice}"
    local inputs=()
    local component

    mkdir -p "${output_dir}"
    for component in "${COMPONENT_LIBRARIES[@]}"; do
        if [[ ! -f "${ffmpeg_lib}/${component}" ]]; then
            echo "Missing FFmpeg component ${component} for ${slice}." >&2
            exit 1
        fi
        inputs+=("${ffmpeg_lib}/${component}")
    done
    if [[ ! -f "${lame_lib}" ]]; then
        echo "Missing libmp3lame.a for ${slice}." >&2
        exit 1
    fi
    inputs+=("${lame_lib}")

    ZERO_AR_DATE=1 xcrun libtool \
        -static \
        -o "${output_dir}/libIllucetMedia.a" \
        "${inputs[@]}"
}

combine_slice ios-arm64
combine_slice simulator-arm64
combine_slice simulator-x86_64

DEVICE_LIBRARY="${STAGING}/combined/ios-arm64/libIllucetMedia.a"
SIMULATOR_ARM64_LIBRARY="${STAGING}/combined/simulator-arm64/libIllucetMedia.a"
SIMULATOR_X86_64_LIBRARY="${STAGING}/combined/simulator-x86_64/libIllucetMedia.a"
SIMULATOR_LIBRARY="${STAGING}/combined/libIllucetMedia.a"

if [[ "$(xcrun lipo -archs "${DEVICE_LIBRARY}")" != "arm64" ]]; then
    echo "Unexpected device library architecture." >&2
    exit 1
fi
if [[ "$(xcrun lipo -archs "${SIMULATOR_ARM64_LIBRARY}")" != "arm64" ]]; then
    echo "Unexpected arm64 simulator library architecture." >&2
    exit 1
fi
if [[ "$(xcrun lipo -archs "${SIMULATOR_X86_64_LIBRARY}")" != "x86_64" ]]; then
    echo "Unexpected x86_64 simulator library architecture." >&2
    exit 1
fi

ZERO_AR_DATE=1 xcrun lipo -create \
    "${SIMULATOR_ARM64_LIBRARY}" \
    "${SIMULATOR_X86_64_LIBRARY}" \
    -output "${SIMULATOR_LIBRARY}"

SIMULATOR_ARCHITECTURES="$(xcrun lipo -archs "${SIMULATOR_LIBRARY}")"
if [[ "${SIMULATOR_ARCHITECTURES}" != "arm64 x86_64" &&
      "${SIMULATOR_ARCHITECTURES}" != "x86_64 arm64" ]]; then
    echo "Unexpected universal simulator architectures: ${SIMULATOR_ARCHITECTURES}" >&2
    exit 1
fi

PACKAGE_HEADERS="${STAGING}/package-headers"
mkdir -p "${PACKAGE_HEADERS}/Licenses"
cp -R "${STAGING}/install/ffmpeg-ios-arm64/include/." "${PACKAGE_HEADERS}/"
cp -R "${STAGING}/install/lame-ios-arm64/include/." "${PACKAGE_HEADERS}/"
cp "${MODULE_MAP}" "${PACKAGE_HEADERS}/IllucetFFmpeg.modulemap"
cp "${FFMPEG_SOURCE}/COPYING.LGPLv2.1" \
    "${PACKAGE_HEADERS}/Licenses/FFmpeg-COPYING.LGPLv2.1.txt"
cp "${FFMPEG_SOURCE}/COPYING.LGPLv3" \
    "${PACKAGE_HEADERS}/Licenses/FFmpeg-COPYING.LGPLv3.txt"
cp "${LAME_SOURCE}/COPYING" \
    "${PACKAGE_HEADERS}/Licenses/LAME-COPYING.LGPLv2.txt"

NEW_DESTINATION="${FRAMEWORK_ROOT}/IllucetMedia.new.$$.xcframework"
run_logged "${LOG_ROOT}/create-xcframework.log" \
    xcodebuild -create-xcframework \
    -library "${DEVICE_LIBRARY}" \
    -headers "${PACKAGE_HEADERS}" \
    -library "${SIMULATOR_LIBRARY}" \
    -headers "${PACKAGE_HEADERS}" \
    -output "${NEW_DESTINATION}"

FIRST_IDENTIFIER="$(
    /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:0:LibraryIdentifier" \
        "${NEW_DESTINATION}/Info.plist"
)"
SECOND_IDENTIFIER="$(
    /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:1:LibraryIdentifier" \
        "${NEW_DESTINATION}/Info.plist"
)"
case "${FIRST_IDENTIFIER}:${SECOND_IDENTIFIER}" in
    ios-arm64:ios-arm64_x86_64-simulator)
        DEVICE_INDEX=0
        SIMULATOR_INDEX=1
        ;;
    ios-arm64_x86_64-simulator:ios-arm64)
        DEVICE_INDEX=1
        SIMULATOR_INDEX=0
        ;;
    *)
        echo "Unexpected XCFramework library identifiers:" >&2
        echo "${FIRST_IDENTIFIER}, ${SECOND_IDENTIFIER}" >&2
        exit 1
        ;;
esac

DEVICE_IDENTIFIER="$(
    /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:${DEVICE_INDEX}:LibraryIdentifier" \
        "${NEW_DESTINATION}/Info.plist"
)"
DEVICE_PLATFORM="$(
    /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:${DEVICE_INDEX}:SupportedPlatform" \
        "${NEW_DESTINATION}/Info.plist"
)"
DEVICE_VARIANT="$(
    /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:${DEVICE_INDEX}:SupportedPlatformVariant" \
        "${NEW_DESTINATION}/Info.plist" 2>/dev/null || true
)"
SIMULATOR_IDENTIFIER="$(
    /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:${SIMULATOR_INDEX}:LibraryIdentifier" \
        "${NEW_DESTINATION}/Info.plist"
)"
SIMULATOR_PLATFORM="$(
    /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:${SIMULATOR_INDEX}:SupportedPlatform" \
        "${NEW_DESTINATION}/Info.plist"
)"
SIMULATOR_VARIANT="$(
    /usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:${SIMULATOR_INDEX}:SupportedPlatformVariant" \
        "${NEW_DESTINATION}/Info.plist"
)"

if [[ "${DEVICE_IDENTIFIER}" != "ios-arm64" ||
      "${DEVICE_PLATFORM}" != "ios" ||
      -n "${DEVICE_VARIANT}" ]]; then
    echo "Unexpected device XCFramework platform metadata." >&2
    exit 1
fi
if [[ "${SIMULATOR_IDENTIFIER}" != "ios-arm64_x86_64-simulator" ||
      "${SIMULATOR_PLATFORM}" != "ios" ||
      "${SIMULATOR_VARIANT}" != "simulator" ]]; then
    echo "Unexpected simulator XCFramework platform metadata." >&2
    exit 1
fi

# Xcode 27 can emit the two otherwise-identical AvailableLibraries entries in
# either order. Normalize only after validating the generated semantics so the
# XCFramework file-tree hash is repeatable too.
CANONICAL_XCFRAMEWORK_LIBRARIES='[{"BinaryPath":"libIllucetMedia.a","HeadersPath":"Headers","LibraryIdentifier":"ios-arm64","LibraryPath":"libIllucetMedia.a","SupportedArchitectures":["arm64"],"SupportedPlatform":"ios"},{"BinaryPath":"libIllucetMedia.a","HeadersPath":"Headers","LibraryIdentifier":"ios-arm64_x86_64-simulator","LibraryPath":"libIllucetMedia.a","SupportedArchitectures":["arm64","x86_64"],"SupportedPlatform":"ios","SupportedPlatformVariant":"simulator"}]'
plutil \
    -replace AvailableLibraries \
    -json "${CANONICAL_XCFRAMEWORK_LIBRARIES}" \
    "${NEW_DESTINATION}/Info.plist"
plutil -convert xml1 "${NEW_DESTINATION}/Info.plist"

PACKAGED_DEVICE_LIBRARY="${NEW_DESTINATION}/${DEVICE_IDENTIFIER}/libIllucetMedia.a"
PACKAGED_SIMULATOR_LIBRARY="${NEW_DESTINATION}/${SIMULATOR_IDENTIFIER}/libIllucetMedia.a"
if [[ "$(xcrun lipo -archs "${PACKAGED_DEVICE_LIBRARY}")" != "arm64" ]]; then
    echo "Packaged device library architecture validation failed." >&2
    exit 1
fi
PACKAGED_SIMULATOR_ARCHITECTURES="$(xcrun lipo -archs "${PACKAGED_SIMULATOR_LIBRARY}")"
if [[ "${PACKAGED_SIMULATOR_ARCHITECTURES}" != "arm64 x86_64" &&
      "${PACKAGED_SIMULATOR_ARCHITECTURES}" != "x86_64 arm64" ]]; then
    echo "Packaged simulator library architecture validation failed." >&2
    exit 1
fi

SYMBOLS="${METADATA_ROOT}/exported-symbols.txt"
xcrun nm -gU "${PACKAGED_DEVICE_LIBRARY}" |
    awk 'NF { print $NF }' |
    LC_ALL=C sort -u > "${SYMBOLS}"
for symbol in \
    _avcodec_version \
    _avformat_version \
    _avfilter_version \
    _avutil_version \
    _swscale_version \
    _swresample_version \
    _lame_init; do
    if ! grep -Fqx "${symbol}" "${SYMBOLS}"; then
        echo "Expected exported symbol is missing: ${symbol}" >&2
        exit 1
    fi
done

SMOKE_SOURCE="${STAGING}/module-smoke.m"
cat > "${SMOKE_SOURCE}" <<'EOF'
@import IllucetFFmpeg;

int main(void) {
    lame_global_flags *lame = lame_init();
    if (lame != 0) {
        lame_close(lame);
    }
    return (int)(
        avcodec_version() +
        avformat_version() +
        avfilter_version() +
        avutil_version() +
        swscale_version() +
        swresample_version()
    );
}
EOF

mkdir -p "${STAGING}/module-cache"
run_logged "${LOG_ROOT}/module-link-smoke.log" \
    xcrun --sdk iphonesimulator clang \
    -arch arm64 \
    -isysroot "${SIMULATOR_SDK_PATH}" \
    "-mios-simulator-version-min=${MINIMUM_IOS_VERSION}" \
    -fmodules \
    -fmodules-cache-path="${STAGING}/module-cache" \
    -fmodule-map-file="${NEW_DESTINATION}/${SIMULATOR_IDENTIFIER}/Headers/IllucetFFmpeg.modulemap" \
    -I"${NEW_DESTINATION}/${SIMULATOR_IDENTIFIER}/Headers" \
    "${SMOKE_SOURCE}" \
    "${PACKAGED_SIMULATOR_LIBRARY}" \
    -framework AudioToolbox \
    -framework VideoToolbox \
    -framework CoreFoundation \
    -framework CoreMedia \
    -framework CoreVideo \
    -lm \
    -lpthread \
    -o "${STAGING}/module-smoke"

DEVICE_SHA256="$(sha256_of "${PACKAGED_DEVICE_LIBRARY}")"
SIMULATOR_SHA256="$(sha256_of "${PACKAGED_SIMULATOR_LIBRARY}")"
HEADER_MANIFEST_SHA256="$(
    sha256_of "${METADATA_ROOT}/ios-arm64-headers.sha256"
)"
XCFRAMEWORK_TREE_SHA256="$(
    (
        cd "${NEW_DESTINATION}"
        find . -type f -print |
            LC_ALL=C sort |
            while IFS= read -r file; do
                printf '%s  %s\n' "$(shasum -a 256 "${file}" | awk '{print $1}')" "${file}"
            done
    ) | shasum -a 256 | awk '{print $1}'
)"

cat > "${METADATA_ROOT}/build-report.txt" <<EOF
IllucetMedia dependency build
FFmpeg version: ${FFMPEG_VERSION}
FFmpeg source SHA-256: ${FFMPEG_SHA256}
FFmpeg signing fingerprint: ${FFMPEG_SIGNING_FINGERPRINT}
LAME version: ${LAME_VERSION}
LAME source SHA-256: ${LAME_SHA256}
Minimum iOS: ${MINIMUM_IOS_VERSION}
Xcode: $(xcodebuild -version | tr '\n' ' ')
iPhoneOS SDK: $(xcrun --sdk iphoneos --show-sdk-version)
iPhoneSimulator SDK: $(xcrun --sdk iphonesimulator --show-sdk-version)
Device platform: ${DEVICE_PLATFORM}
Device architectures: arm64
Simulator platform/variant: ${SIMULATOR_PLATFORM}/${SIMULATOR_VARIANT}
Simulator architectures: ${PACKAGED_SIMULATOR_ARCHITECTURES}
Device library SHA-256: ${DEVICE_SHA256}
Simulator library SHA-256: ${SIMULATOR_SHA256}
Public-header manifest SHA-256: ${HEADER_MANIFEST_SHA256}
XCFramework file-tree SHA-256: ${XCFRAMEWORK_TREE_SHA256}
Required system links: AudioToolbox VideoToolbox CoreFoundation CoreMedia CoreVideo m pthread
EOF

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

echo "IllucetMedia XCFramework created: ${DESTINATION}"
echo "FFmpeg ${FFMPEG_VERSION}; LAME ${LAME_VERSION}; minimum iOS ${MINIMUM_IOS_VERSION}"
echo "Device: ${DEVICE_PLATFORM} arm64"
echo "Simulator: ${SIMULATOR_PLATFORM}/${SIMULATOR_VARIANT} ${PACKAGED_SIMULATOR_ARCHITECTURES}"
echo "Device library SHA-256: ${DEVICE_SHA256}"
echo "Simulator library SHA-256: ${SIMULATOR_SHA256}"
echo "Public-header manifest SHA-256: ${HEADER_MANIFEST_SHA256}"
echo "XCFramework file-tree SHA-256: ${XCFRAMEWORK_TREE_SHA256}"
echo "Configuration and license evidence: ${METADATA_ROOT}"
