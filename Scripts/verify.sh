#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"

fail() { printf 'verify: %s\n' "$1" >&2; exit 2; }
need_file() { [[ -f "$1" ]] || fail "required input is missing: $1"; }

static() {
    need_file "$ROOT/Config/Dependencies.sh"
    need_file "$ROOT/Vendor/PythonPackages/yt_dlp/version.py"
    python3 "$ROOT/Scripts/tests/test_publish_release.py"
    python3 "$ROOT/Scripts/tests/test_verify_project_state.py"
    python3 "$ROOT/Scripts/tests/test_verify_branding.py"
    python3 "$ROOT/Scripts/tests/test_verify_public_package.py"
    python3 "$ROOT/Scripts/tests/test_restore_runtime_dependencies.py"
    python3 "$ROOT/Scripts/tests/test_sanitize_python_package_metadata.py"
    python3 "$ROOT/Scripts/verify-branding.py"
    python3 "$ROOT/Scripts/verify-public-package.py" --source
    python3 "$ROOT/Scripts/tests/test_verify_python_package_bundle.py"
    python3 "$ROOT/Scripts/tests/test_extractor_profiles.py"
    python3 "$ROOT/Scripts/verify-project-state.py"
    python3 "$ROOT/Scripts/sync-dependency-versions.py" --check
    python3 "$ROOT/Scripts/verify-python-package-bundle.py" \
        --config "$ROOT/Config/Dependencies.sh" "$ROOT/Vendor/PythonPackages"
    PYTHONPATH="$ROOT/PythonApp:$ROOT/Vendor/PythonPackages" \
        python3 -m unittest discover -s "$ROOT/PythonApp/tests" -p 'test_*.py'
}

native_test() {
    [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]] || \
        fail "set DEVELOPER_DIR to the selected Xcode developer directory"
    [[ -n "${ILLUCET_SIMULATOR_ID:-}" ]] || \
        fail "set ILLUCET_SIMULATOR_ID to an explicit simulator UUID"
    need_file "$ROOT/IllucetApp.xcodeproj/project.pbxproj"
    local run_dir
    run_dir="$(mktemp -d "${TMPDIR:-/tmp}/illucet-verify.XXXXXX")"
    local derived_data="${ILLUCET_DERIVED_DATA_PATH:-$run_dir/DerivedData}"
    printf 'XCTest result bundle: %s/results.xcresult\n' "$run_dir"
    xcodebuild -project "$ROOT/IllucetApp.xcodeproj" -scheme Illucet \
        -destination "platform=iOS Simulator,id=$ILLUCET_SIMULATOR_ID" \
        -derivedDataPath "$derived_data" \
        -resultBundlePath "$run_dir/results.xcresult" test \
        CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- "$@"
    verify_test_results "$run_dir/results.xcresult" "$run_dir"
}

verify_test_results() {
    local result_path="$1" run_dir="$2" expect_live="${3:-0}"
    DEVELOPER_DIR="$DEVELOPER_DIR" xcrun xcresulttool \
        get test-results summary --path "$result_path" > "$run_dir/summary.json"
    DEVELOPER_DIR="$DEVELOPER_DIR" xcrun xcresulttool \
        get test-results tests --path "$result_path" > "$run_dir/tests.json"
    python3 - "$run_dir/summary.json" "$run_dir/tests.json" "$expect_live" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    summary = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    tests = json.load(stream)
count = summary.get("totalTestCount", 0)
if count < 1:
    raise SystemExit("verification failed: XCTest executed zero tests")
if sys.argv[3] != "0":
    expected = {"part13": "authorizedPart13CreatorAndSidecarSmoke()", "updater": "officialExtractorUpdateStagesActivatesAndRestoresBundled()",
                "account": "savedAccountDownloadsAuthorizedPublicVideoAfterRelaunch()",
                "benchmark": "authorizedDownloadBenchmark()"}.get(
                    sys.argv[3], "authorizedLiveVideoDownloadSmoke()")
    def leaves(nodes):
        for node in nodes:
            if node.get("nodeType") == "Test Case":
                yield node
            yield from leaves(node.get("children", []))
    selected = [node for node in leaves(tests.get("testNodes", []))
                if node.get("name") == expected or expected in node.get("nodeIdentifier", "")]
    if (count != 1 or summary.get("passedTests") != 1 or
            summary.get("skippedTests") != 0 or len(selected) != 1 or
            selected[0].get("result") != "Passed"):
        raise SystemExit("verification failed: authorized live test did not pass exactly once")
    print("Authorized live test passed exactly once.")
else:
    print(f"XCTest executed {count} test(s).")
PY
}

live_test() {
    local live_kind="${1:-media}"
    local live_method="DownloadCoordinatorTests/authorizedLiveVideoDownloadSmoke()"
    [[ "$live_kind" != "updater" ]] || live_method="EmbeddedRuntimeTests/officialExtractorUpdateStagesActivatesAndRestoresBundled()"
    [[ "$live_kind" != "part13" ]] || live_method="DownloadCoordinatorTests/authorizedPart13CreatorAndSidecarSmoke()"
    [[ "$live_kind" != "benchmark" ]] || live_method="DownloadCoordinatorTests/authorizedDownloadBenchmark()"
    [[ "$live_kind" != "account" ]] || live_method="EmbeddedRuntimeTests/savedAccountDownloadsAuthorizedPublicVideoAfterRelaunch()"
    [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]] || \
        fail "set DEVELOPER_DIR to the selected Xcode developer directory"
    [[ -n "${ILLUCET_SIMULATOR_ID:-}" ]] || \
        fail "set ILLUCET_SIMULATOR_ID to an explicit simulator UUID"
    need_file "$ROOT/IllucetApp.xcodeproj/project.pbxproj"
    local run_dir derived_data products xctestrun live_xctestrun
    run_dir="$(mktemp -d "${TMPDIR:-/tmp}/illucet-live-verify.XXXXXX")"
    derived_data="${ILLUCET_DERIVED_DATA_PATH:-$run_dir/DerivedData}"
    printf 'XCTest result bundle: %s/results.xcresult\n' "$run_dir"
    simulator_sdk="$(DEVELOPER_DIR="$DEVELOPER_DIR" xcrun --sdk iphonesimulator --show-sdk-version)"
    simulator_arch="$(uname -m)"
    mkdir -p "$derived_data/Build/Products"
    touch "$run_dir/build-start"
    xcodebuild -project "$ROOT/IllucetApp.xcodeproj" -scheme Illucet \
        -destination "platform=iOS Simulator,id=$ILLUCET_SIMULATOR_ID" \
        -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
    products="$derived_data/Build/Products"
    xctestrun="$products/Illucet_iphonesimulator${simulator_sdk}-${simulator_arch}.xctestrun"
    [[ -f "$xctestrun" ]] || fail "xcodebuild did not produce the current simulator test runner: $(basename "$xctestrun")"
    [[ "$xctestrun" -nt "$run_dir/build-start" ]] || fail "simulator test runner was not refreshed by this build"
    live_xctestrun="$products/Illucet_iphonesimulator${simulator_sdk}-${simulator_arch}-authorized-live.xctestrun"
    python3 - "$xctestrun" "$live_xctestrun" "${config:-}" "$live_kind" <<'PY'
import os, plistlib, shutil, sys
source, destination, config, kind = sys.argv[1:]
shutil.copy2(source, destination)
with open(destination, "rb") as stream:
    run = plistlib.load(stream)
tests = run.get("IllucetTests")
if not isinstance(tests, dict) or not isinstance(tests.get("EnvironmentVariables"), dict):
    raise SystemExit(".xctestrun is missing IllucetTests.EnvironmentVariables")
if kind == "part13":
    tests["EnvironmentVariables"]["ILLUCET_PART13_LIVE"] = "1"
elif kind == "updater":
    channel = os.environ.get("ILLUCET_UPDATER_CHANNEL", "Nightly")
    if channel not in {"Master", "Nightly", "Stable"}:
        raise SystemExit("set ILLUCET_UPDATER_CHANNEL to Master, Nightly or Stable")
    tests["EnvironmentVariables"]["ILLUCET_EXTRACTOR_UPDATE_TESTS"] = "1"
    tests["EnvironmentVariables"]["ILLUCET_UPDATER_CHANNEL"] = channel
    tests["EnvironmentVariables"]["ILLUCET_UPDATER_COMPARE_BUNDLED"] = os.environ.get("ILLUCET_UPDATER_COMPARE_BUNDLED", "0")
    if os.environ.get("ILLUCET_UPDATER_TEST_FORMATS"):
        if os.environ.get("ILLUCET_UPDATER_COMPARE_BUNDLED") != "1":
            raise SystemExit("ILLUCET_UPDATER_TEST_FORMATS requires ILLUCET_UPDATER_COMPARE_BUNDLED=1")
        tests["EnvironmentVariables"]["ILLUCET_UPDATER_TEST_FORMATS"] = os.environ["ILLUCET_UPDATER_TEST_FORMATS"]
    if config:
        tests["EnvironmentVariables"]["ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH"] = config
elif kind == "account":
    import os
    tests["EnvironmentVariables"]["ILLUCET_AUTHORIZED_ACCOUNT_TEST_NAME"] = os.environ["ILLUCET_AUTHORIZED_ACCOUNT_TEST_NAME"]
else:
    tests["EnvironmentVariables"].update({
        "ILLUCET_STAGE0_LIVE_TESTS": "1",
        "ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH": config,
        "ILLUCET_LIVE_CHAPTERS": os.environ.get("ILLUCET_LIVE_CHAPTERS", "0"),
        "ILLUCET_LIVE_INCLUDE_THUMBNAIL": os.environ.get("ILLUCET_LIVE_INCLUDE_THUMBNAIL", "0"),
        "ILLUCET_LIVE_BACKGROUND_RECOVERY": os.environ.get("ILLUCET_LIVE_BACKGROUND_RECOVERY", "0"),
    })
if kind == "benchmark":
    height = os.environ.get("ILLUCET_BENCHMARK_HEIGHT", "")
    if height not in {"144", "240", "360", "480", "720", "1080", "1440", "2160"}:
        raise SystemExit("set ILLUCET_BENCHMARK_HEIGHT to a supported resolution")
    tests["EnvironmentVariables"].update({"ILLUCET_DOWNLOAD_BENCHMARK": "1",
        "ILLUCET_BENCHMARK_HEIGHT": height})
with open(destination, "wb") as stream:
    plistlib.dump(run, stream, fmt=plistlib.FMT_XML, sort_keys=False)
PY
    xcodebuild -xctestrun "$live_xctestrun" \
        -destination "platform=iOS Simulator,id=$ILLUCET_SIMULATOR_ID" \
        -resultBundlePath "$run_dir/results.xcresult" test-without-building \
        "-only-testing:IllucetTests/$live_method"
    verify_test_results "$run_dir/results.xcresult" "$run_dir" "$live_kind"
}

validate_live_config() {
    local supplied="$1"
    [[ "$supplied" = /* && -f "$supplied" ]] || \
        fail "ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH must name an existing absolute plist"
    if [[ "$supplied" = "$ROOT/"* ]] && git -C "$ROOT" ls-files --error-unmatch "$supplied" >/dev/null 2>&1; then
        fail "live test config must not be tracked by Git"
    fi
    python3 - "$supplied" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as stream:
    config = plistlib.load(stream)
if config.get("LiveTestsEnabled") is not True:
    raise SystemExit("live test config must set LiveTestsEnabled to true")
PY
}

case "$MODE" in
    static)
        static
        ;;
        simulator)
        static
        native_test \
            -only-testing:IllucetTests \
            '-skip-testing:IllucetTests/DownloadCoordinatorTests/authorizedLiveDownloaderSmoke(_:)' \
            '-skip-testing:IllucetTests/DownloadCoordinatorTests/authorizedLiveVideoDownloadSmoke()' \
            '-skip-testing:IllucetTests/DownloadCoordinatorTests/authorizedDownloadBenchmark()' \
            '-skip-testing:IllucetTests/DownloadCoordinatorTests/authorizedPart13CreatorAndSidecarSmoke()' \
            '-skip-testing:IllucetTests/EmbeddedRuntimeTests/savedAccountDownloadsAuthorizedPublicVideoAfterRelaunch()' \
            '-skip-testing:IllucetTests/EmbeddedRuntimeTests/officialExtractorUpdateStagesActivatesAndRestoresBundled()'
        ;;
    live|benchmark)
        static
        config="${ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH:-}"
        validate_live_config "$config"
        live_test "$MODE"
        ;;
    part13-live)
        live_test part13
        ;;
    updater-live)
        static
        config="${ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH:-}"
        if [[ -n "$config" ]]; then validate_live_config "$config"; fi
        live_test updater
        ;;
    account-live)
        [[ -n "${ILLUCET_AUTHORIZED_ACCOUNT_TEST_NAME:-}" ]] || \
            fail "set ILLUCET_AUTHORIZED_ACCOUNT_TEST_NAME to the explicitly authorized saved profile label"
        static
        live_test account
        ;;
    *)
        fail "usage: Scripts/verify.sh {static|simulator|live|benchmark|part13-live|updater-live|account-live}"
        ;;
esac
