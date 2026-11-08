"""Typed JSON boundary used only by Illucet's native Python bridge."""

from __future__ import annotations

import hashlib
import json
import platform
import sys
import time
from typing import Any

import _illucet_native
import illucet_ytdlp_extractor
import illucet_ytdlp_provider


class IllucetProofError(RuntimeError):
    """Deterministic error used to prove exception mapping."""


class IllucetCancelled(RuntimeError):
    """Raised only at a cooperative cancellation checkpoint."""


def _event(kind: str, **payload: Any) -> None:
    _illucet_native.emit_json(
        json.dumps(
            {"kind": kind, "payload": payload},
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    )


def _envelope(action: str, data: dict[str, Any]) -> str:
    return json.dumps(
        {"ok": True, "action": action, "data": data},
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def _error_envelope(
    action: str,
    error: illucet_ytdlp_extractor.SafeExtractionFailure,
) -> str:
    return json.dumps(
        {
            "ok": False,
            "action": action,
            "error": {
                "code": error.code,
                "message": error.message,
                "retryable": error.retryable,
            },
        },
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def _basic() -> str:
    import bundle_probe
    import certifi
    import ssl
    import writable_probe
    from yt_dlp.version import __version__ as yt_dlp_version
    from yt_dlp_ejs._version import __version__ as ejs_version

    _event("log", level="info", message="Python basic proof started")
    _event("progress", completed=1, total=1)
    return _envelope(
        "basic",
        {
            "addition": 2 + 3,
            "bundle_origin": bundle_probe.ORIGIN,
            "certifi_version": certifi.__version__,
            "ejs_version": ejs_version,
            "is_main_thread": _illucet_native.is_main_thread(),
            "platform": sys.platform,
            "platform_detail": platform.platform(),
            "python_version": platform.python_version(),
            "ssl_version": ssl.OPENSSL_VERSION,
            "writable_origin": writable_probe.ORIGIN,
            "yt_dlp_version": yt_dlp_version,
        },
    )


def _delay(request: dict[str, Any]) -> str:
    steps = max(1, min(int(request.get("steps", 20)), 10_000))
    interval = max(0.0, min(float(request.get("interval", 0.01)), 1.0))
    started = time.monotonic()
    _event("started", monotonic=started)

    for step in range(steps):
        if _illucet_native.is_cancelled():
            _event("cancelled", completed=step, total=steps)
            raise IllucetCancelled("The native cancellation flag was observed.")
        time.sleep(interval)
        _event("progress", completed=step + 1, total=steps)

    if _illucet_native.is_cancelled():
        _event("cancelled", completed=steps, total=steps)
        raise IllucetCancelled("The native cancellation flag was observed.")

    finished = time.monotonic()
    _event("finished", monotonic=finished)
    return _envelope(
        "delay",
        {
            "finished": finished,
            "is_main_thread": _illucet_native.is_main_thread(),
            "started": started,
        },
    )


def _quickjs() -> str:
    thrown_secret = "super secret password"
    try:
        _illucet_native.quickjs_evaluate(
            f"throw {json.dumps(thrown_secret)};",
            16 * 1024 * 1024,
            1 * 1024 * 1024,
            1_000,
            1 * 1024 * 1024,
        )
    except RuntimeError as error:
        thrown_error = str(error)
        thrown_text_redacted = (
            thrown_secret not in thrown_error
            and "safe thrown text" not in thrown_error.lower()
            and "redacted string value" in thrown_error.lower()
        )
    else:
        raise IllucetProofError(
            "QuickJS accepted an explicitly thrown string."
        )

    basic_output = _illucet_native.quickjs_evaluate(
        (
            "console.log(JSON.stringify({"
            "answer: 6 * 7,"
            "unicode: 'Illucet 🔐'"
            "}));"
        ),
        16 * 1024 * 1024,
        1 * 1024 * 1024,
        1_000,
        1 * 1024 * 1024,
    )
    started = time.monotonic()
    provider_proof = illucet_ytdlp_provider.run_initialized_provider_smoke()
    fail_closed_proof = (
        illucet_ytdlp_provider.run_fail_closed_director_smoke()
    )
    finished = time.monotonic()
    basic_result = json.loads(basic_output)
    ejs_result = json.loads(str(provider_proof["output"]))
    core = str(provider_proof["core_code"])
    library = str(provider_proof["library_code"])
    return _envelope(
        "quickjs",
        {
            **illucet_ytdlp_provider.contract_details(),
            "answer": basic_result["answer"],
            "core_sha256": hashlib.sha256(core.encode()).hexdigest(),
            "elapsed": finished - started,
            "empty_response_count": len(ejs_result["responses"]),
            "empty_result_type": ejs_result["type"],
            "fail_closed_cases": fail_closed_proof["case_results"],
            "fail_closed_director": fail_closed_proof["all_cases_passed"],
            "lib_sha256": hashlib.sha256(library.encode()).hexdigest(),
            "provider_available": provider_proof["available"],
            "sensitive_director_log_found": fail_closed_proof[
                "sensitive_log_found"
            ],
            "thrown_text_redacted": thrown_text_redacted,
            "unicode": basic_result["unicode"],
        },
    )


def _quickjs_timeout() -> str:
    class _TimeoutProofJCP(
        illucet_ytdlp_provider.IllucetQuickJSJCP
    ):
        QUICKJS_TIMEOUT_MILLISECONDS = 50

    provider = _TimeoutProofJCP(
        illucet_ytdlp_provider._ProofInfoExtractor(),
        illucet_ytdlp_provider._ProofLogger(),
        {},
    )
    started = time.monotonic()
    try:
        provider._run_js_runtime("while (true) {}")
    except illucet_ytdlp_provider.IllucetProviderFailure as error:
        if "TimeoutError" not in str(error):
            raise
        return _envelope(
            "quickjs_timeout",
            {
                "elapsed": time.monotonic() - started,
                "error_type": "TimeoutError",
                "provider_error_type": type(error).__name__,
            },
        )
    raise IllucetProofError("QuickJS infinite loop ignored its deadline")


def _quickjs_spin() -> str:
    provider = illucet_ytdlp_provider.IllucetQuickJSJCP(
        illucet_ytdlp_provider._ProofInfoExtractor(),
        illucet_ytdlp_provider._ProofLogger(),
        {},
    )
    provider._run_js_runtime("while (true) {}")
    raise IllucetProofError("QuickJS infinite loop completed unexpectedly")


def _extract_metadata(request: dict[str, Any]) -> str:
    try:
        data = illucet_ytdlp_extractor.extract_metadata(
            request,
            emit_event=_event,
        )
    except illucet_ytdlp_provider.IllucetProviderCancelled:
        raise IllucetCancelled(
            "The native cancellation flag interrupted metadata extraction."
        ) from None
    except illucet_ytdlp_extractor.SafeExtractionFailure as error:
        _event("log", level="warning", message=error.code)
        return _error_envelope("extract_metadata", error)
    except illucet_ytdlp_provider.IllucetProviderFailure as error:
        safe_error = illucet_ytdlp_extractor.classify_extraction_error(
            error
        )
        _event("log", level="warning", message=safe_error.code)
        return _error_envelope("extract_metadata", safe_error)
    except Exception as error:
        safe_error = illucet_ytdlp_extractor.classify_extraction_error(
            error
        )
        _event("log", level="warning", message=safe_error.code)
        return _error_envelope("extract_metadata", safe_error)
    response = _envelope("extract_metadata", data)
    if len(response.encode("utf-8")) > illucet_ytdlp_extractor._MAX_OUTPUT_BYTES:
        return _error_envelope("extract_metadata", illucet_ytdlp_extractor.SafeExtractionFailure(
            "metadata_too_large",
            "The extracted metadata exceeds Illucet's output limit.",
        ))
    return response


def _extract_playlist(request: dict[str, Any]) -> str:
    try:
        data = illucet_ytdlp_extractor.extract_playlist(
            request,
            emit_event=_event,
        )
    except illucet_ytdlp_provider.IllucetProviderCancelled:
        raise IllucetCancelled(
            "The native cancellation flag interrupted playlist analysis."
        ) from None
    except illucet_ytdlp_extractor.SafeExtractionFailure as error:
        _event("log", level="warning", message=error.code)
        return _error_envelope("extract_playlist", error)
    except Exception as error:
        safe_error = illucet_ytdlp_extractor.classify_extraction_error(
            error
        )
        _event("log", level="warning", message=safe_error.code)
        return _error_envelope("extract_playlist", safe_error)
    return _envelope("extract_playlist", data)


def _resolve_streams(request: dict[str, Any]) -> str:
    try:
        data = illucet_ytdlp_extractor.resolve_streams(
            request,
            emit_event=_event,
        )
    except illucet_ytdlp_provider.IllucetProviderCancelled:
        raise IllucetCancelled(
            "The native cancellation flag interrupted stream resolution."
        ) from None
    except illucet_ytdlp_extractor.SafeExtractionFailure as error:
        _event("log", level="warning", message=error.code)
        return _error_envelope("resolve_streams", error)
    except Exception as error:
        safe_error = illucet_ytdlp_extractor.classify_extraction_error(
            error
        )
        _event("log", level="warning", message=safe_error.code)
        return _error_envelope("resolve_streams", safe_error)
    return _envelope("resolve_streams", data)


def _resolve_dash_fragment_plan(request: dict[str, Any]) -> str:
    try:
        data = illucet_ytdlp_extractor.resolve_dash_fragment_plan(
            request,
            emit_event=_event,
        )
    except illucet_ytdlp_provider.IllucetProviderCancelled:
        raise IllucetCancelled(
            "The native cancellation flag interrupted DASH fragment resolution."
        ) from None
    except illucet_ytdlp_extractor.SafeExtractionFailure as error:
        _event("log", level="warning", message=error.code)
        return _error_envelope("resolve_dash_fragment_plan", error)
    except Exception as error:
        safe_error = illucet_ytdlp_extractor.classify_extraction_error(
            error
        )
        _event("log", level="warning", message=safe_error.code)
        return _error_envelope("resolve_dash_fragment_plan", safe_error)
    return _envelope("resolve_dash_fragment_plan", data)


def _resolve_hls_playlist_plan(request: dict[str, Any]) -> str:
    try:
        data = illucet_ytdlp_extractor.resolve_hls_playlist_plan(
            request,
            emit_event=_event,
        )
    except illucet_ytdlp_provider.IllucetProviderCancelled:
        raise IllucetCancelled(
            "The native cancellation flag interrupted HLS playlist resolution."
        ) from None
    except illucet_ytdlp_extractor.SafeExtractionFailure as error:
        _event("log", level="warning", message=error.code)
        return _error_envelope("resolve_hls_playlist_plan", error)
    except Exception as error:
        safe_error = illucet_ytdlp_extractor.classify_extraction_error(
            error
        )
        _event("log", level="warning", message=safe_error.code)
        return _error_envelope("resolve_hls_playlist_plan", safe_error)
    return _envelope("resolve_hls_playlist_plan", data)


def handle_request(request_json: str) -> str:
    if _illucet_native.is_cancelled():
        raise IllucetCancelled(
            "The native cancellation flag was set before Python dispatch."
        )

    request = json.loads(request_json)
    action = request.get("action")

    if action == "probe_youtube_session":
        from illucet_session_probe import probe
        try:
            return _envelope(action, probe(request))
        except illucet_ytdlp_provider.IllucetProviderCancelled:
            raise IllucetCancelled("Session probe cancelled.") from None
        except illucet_ytdlp_extractor.SafeExtractionFailure as error:
            return _error_envelope(action, error)
        except Exception as error:
            return _error_envelope(action,
                illucet_ytdlp_extractor.classify_extraction_error(error))

    if action == "stage_extractor_packages":
        from illucet_package_install import extract_packages
        return _envelope(action, extract_packages(request["archives"], request["destination"]))
    if action == "inspect_master_extractor_archive":
        from illucet_package_install import inspect_master_archive
        return _envelope(action, inspect_master_archive(request["archive"]))
    if action == "validate_extractor_runtime":
        illucet_ytdlp_provider._assert_runtime_contract()
        proof = illucet_ytdlp_provider.run_initialized_provider_smoke()
        if not proof.get("available"):
            raise IllucetProofError("The extractor JavaScript provider is unavailable")
        return _envelope(action, {
            "ytDLP": proof["yt_dlp_version"], "ejs": proof["ejs_version"],
            "quickJS": proof["quickjs_version"],
            "ejsCoreSHA3512": proof["core_hash"],
            "ejsLibrarySHA3512": proof["library_hash"],
        })
    if action == "runtime_versions":
        import ssl
        illucet_ytdlp_provider._assert_runtime_contract()
        return _envelope(action, {
            **illucet_ytdlp_provider.contract_details(),
            "python_version": platform.python_version(),
            "openssl_version": ssl.OPENSSL_VERSION,
        })

    if action == "basic":
        return _basic()
    if action == "exception":
        raise IllucetProofError("deterministic exception crossing the bridge")
    if action == "sensitive_exception":
        raise IllucetProofError(
            "COOKIE=secret; Authorization: Bearer secret; sig=secret"
        )
    if action == "delay":
        return _delay(request)
    if action == "quickjs":
        return _quickjs()
    if action == "quickjs_timeout":
        return _quickjs_timeout()
    if action == "quickjs_spin":
        return _quickjs_spin()
    if action == "extract_metadata":
        return _extract_metadata(request)
    if action == "extract_playlist":
        return _extract_playlist(request)
    if action == "resolve_streams":
        return _resolve_streams(request)
    if action == "resolve_dash_fragment_plan":
        return _resolve_dash_fragment_plan(request)
    if action == "resolve_hls_playlist_plan":
        return _resolve_hls_playlist_plan(request)

    raise ValueError(f"Unsupported bridge action: {action!r}")
