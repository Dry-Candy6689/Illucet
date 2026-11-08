"""Pinned in-process yt-dlp EJS provider for Illucet on iOS.

This is deliberately a small downstream adapter over yt-dlp's private
EJSBaseJCP seam. Its import/contract test must pass for every yt-dlp/EJS update.
"""

from __future__ import annotations

import contextvars
import _illucet_native
from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
from yt_dlp.extractor.youtube.jsc._director import (
    JsChallengeRequestDirector,
    validate_provider_response,
    validate_response,
)
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProvider,
    JsChallengeProviderError,
    JsChallengeProviderResponse,
    JsChallengeRequest,
    JsChallengeResponse,
    JsChallengeType,
    NChallengeInput,
    NChallengeOutput,
    SigChallengeInput,
    SigChallengeOutput,
    register_preference,
    register_provider,
)
from yt_dlp.extractor.youtube.pot._provider import (
    BuiltinIEContentProvider,
    IEContentProviderLogger,
)
from yt_dlp.version import __version__ as ytdlp_version
from yt_dlp_ejs._version import __version__ as ejs_version

from illucet_runtime_contract import expected_versions

EXPECTED_YTDLP_VERSION, EXPECTED_EJS_VERSION, EXPECTED_QUICKJS_VERSION = expected_versions()

_active_extraction_diagnostics: contextvars.ContextVar[
    dict[str, object] | None
] = contextvars.ContextVar(
    "illucet_active_extraction_diagnostics",
    default=None,
)


class IllucetProviderFailure(BaseException):
    """Stops extraction instead of accepting an incomplete JS fallback."""

    def __init__(
        self,
        message: str,
        *,
        reason: str = "provider_failure",
    ) -> None:
        super().__init__(message)
        self.reason = reason


class IllucetProviderCancelled(BaseException):
    """Bypasses yt-dlp's fallback handling for explicit user cancellation."""


def begin_extraction_diagnostics() -> contextvars.Token:
    """Start request-local, secret-free provider diagnostics."""

    return _active_extraction_diagnostics.set(
        {
            "challenge_provider_used": False,
            "provider_constructed_count": 0,
            "provider_available_count": 0,
            "provider_available": False,
            "bulk_solve_call_count": 0,
            "challenge_request_count": 0,
            "challenge_response_count": 0,
            "challenge_types": set(),
            "challenge_request_counts": {"n": 0, "sig": 0},
            "challenge_response_counts": {"n": 0, "sig": 0},
            "runtime_call_count": 0,
            "runtime_error_count": 0,
            "runtime_cancellation_count": 0,
            "runtime_timeout_count": 0,
            "provider_failure_count": 0,
            "ejs_core_sha3_512": None,
            "ejs_library_sha3_512": None,
        }
    )


def finish_extraction_diagnostics(
    token: contextvars.Token,
) -> dict[str, object]:
    """Snapshot and clear diagnostics without retaining challenge inputs."""

    current = _active_extraction_diagnostics.get()
    if current is None:
        snapshot: dict[str, object] = {
            "challenge_provider_used": False,
            "provider_constructed_count": 0,
            "provider_available_count": 0,
            "provider_available": False,
            "bulk_solve_call_count": 0,
            "challenge_request_count": 0,
            "challenge_response_count": 0,
            "challenge_types": [],
            "challenge_request_counts": {"n": 0, "sig": 0},
            "challenge_response_counts": {"n": 0, "sig": 0},
            "runtime_call_count": 0,
            "runtime_error_count": 0,
            "runtime_cancellation_count": 0,
            "runtime_timeout_count": 0,
            "provider_failure_count": 0,
            "ejs_core_sha3_512": None,
            "ejs_library_sha3_512": None,
        }
    else:
        challenge_types = current.get("challenge_types", set())
        snapshot = {
            "challenge_provider_used": bool(
                current.get("challenge_provider_used")
            ),
            "provider_constructed_count": int(
                current.get("provider_constructed_count", 0)
            ),
            "provider_available_count": int(
                current.get("provider_available_count", 0)
            ),
            "provider_available": bool(
                current.get("provider_available")
            ),
            "bulk_solve_call_count": int(
                current.get("bulk_solve_call_count", 0)
            ),
            "challenge_request_count": int(
                current.get("challenge_request_count", 0)
            ),
            "challenge_response_count": int(
                current.get("challenge_response_count", 0)
            ),
            "challenge_types": sorted(
                str(challenge_type)
                for challenge_type in challenge_types
            ),
            "challenge_request_counts": dict(
                current.get(
                    "challenge_request_counts",
                    {"n": 0, "sig": 0},
                )
            ),
            "challenge_response_counts": dict(
                current.get(
                    "challenge_response_counts",
                    {"n": 0, "sig": 0},
                )
            ),
            "runtime_call_count": int(
                current.get("runtime_call_count", 0)
            ),
            "runtime_error_count": int(
                current.get("runtime_error_count", 0)
            ),
            "runtime_cancellation_count": int(
                current.get("runtime_cancellation_count", 0)
            ),
            "runtime_timeout_count": int(
                current.get("runtime_timeout_count", 0)
            ),
            "provider_failure_count": int(
                current.get("provider_failure_count", 0)
            ),
            "ejs_core_sha3_512": current.get("ejs_core_sha3_512"),
            "ejs_library_sha3_512": current.get(
                "ejs_library_sha3_512"
            ),
        }
    _active_extraction_diagnostics.reset(token)
    return snapshot


def _record_challenge_requests(
    requests: list[JsChallengeRequest],
) -> None:
    diagnostics = _active_extraction_diagnostics.get()
    if diagnostics is None or not requests:
        return
    diagnostics["challenge_provider_used"] = True
    diagnostics["challenge_request_count"] = int(
        diagnostics["challenge_request_count"]
    ) + len(requests)
    diagnostics["bulk_solve_call_count"] = int(
        diagnostics["bulk_solve_call_count"]
    ) + 1
    challenge_types = diagnostics["challenge_types"]
    request_counts = diagnostics["challenge_request_counts"]
    if isinstance(challenge_types, set):
        challenge_types.update(request.type.value for request in requests)
    if isinstance(request_counts, dict):
        for request in requests:
            request_type = request.type.value
            request_counts[request_type] = int(
                request_counts.get(request_type, 0)
            ) + 1


def _record_challenge_responses(
    responses: list[JsChallengeProviderResponse],
) -> None:
    diagnostics = _active_extraction_diagnostics.get()
    if diagnostics is None:
        return
    diagnostics["challenge_response_count"] = int(
        diagnostics["challenge_response_count"]
    ) + len(responses)
    response_counts = diagnostics["challenge_response_counts"]
    if isinstance(response_counts, dict):
        for response in responses:
            response_type = response.request.type.value
            response_counts[response_type] = int(
                response_counts.get(response_type, 0)
            ) + 1


def _increment_diagnostic(name: str) -> None:
    diagnostics = _active_extraction_diagnostics.get()
    if diagnostics is None:
        return
    diagnostics[name] = int(diagnostics.get(name, 0)) + 1


def _record_provider_available() -> None:
    diagnostics = _active_extraction_diagnostics.get()
    if diagnostics is None:
        return
    _increment_diagnostic("provider_available_count")
    diagnostics["provider_available"] = True


def _record_ejs_hashes(provider: "IllucetQuickJSJCP") -> None:
    diagnostics = _active_extraction_diagnostics.get()
    if diagnostics is None:
        return
    diagnostics["ejs_core_sha3_512"] = provider._core_script.hash
    diagnostics["ejs_library_sha3_512"] = provider._lib_script.hash


def _assert_runtime_contract() -> None:
    actual = {
        "yt-dlp": ytdlp_version,
        "EJS": ejs_version,
        "QuickJS-ng": _illucet_native.quickjs_version(),
    }
    expected = {
        "yt-dlp": EXPECTED_YTDLP_VERSION,
        "EJS": EXPECTED_EJS_VERSION,
        "QuickJS-ng": EXPECTED_QUICKJS_VERSION,
    }
    mismatches = [
        f"{name} expected {expected[name]}, found {actual[name]}"
        for name in expected
        if actual[name] != expected[name]
    ]
    if mismatches:
        raise IllucetProviderFailure(
            "Illucet JavaScript provider contract mismatch: "
            + "; ".join(mismatches),
            reason="runtime_contract_mismatch",
        )


def _classify_runtime_failure(error: BaseException) -> str:
    """Return a fixed diagnostic category without exposing challenge data."""

    if isinstance(error, OverflowError):
        return "runtime_output_limit"
    message = str(error).lower()
    for marker, reason in (
        ("unexpected structure", "ejs_unexpected_player_structure"),
        ("unexpected player structure", "ejs_unexpected_player_structure"),
        ("no solutions:", "ejs_no_solutions"),
        ("no challenge solution", "ejs_no_solutions"),
        ("invalid solutions:", "ejs_conflicting_solutions"),
        ("conflicting challenge solutions", "ejs_conflicting_solutions"),
        ("failed to extract", "ejs_extraction_failure"),
        ("challenge extraction failed", "ejs_extraction_failure"),
        ("unclassified non-error", "runtime_thrown_value"),
        ("redacted string value", "runtime_thrown_string"),
        ("redacted object value", "runtime_thrown_object"),
        ("parseerror object", "ejs_player_parse_error"),
        ("syntaxerror object", "runtime_syntax_error"),
        ("typeerror object", "runtime_type_error"),
        ("redacted numeric value", "runtime_thrown_number"),
        ("redacted boolean value", "runtime_thrown_boolean"),
        ("quickjs threw null", "runtime_thrown_null"),
        ("quickjs threw undefined", "runtime_thrown_undefined"),
        ("not a function", "runtime_not_a_function"),
        ("not defined", "runtime_missing_global"),
        ("cannot convert", "runtime_conversion_error"),
        ("invalid character", "runtime_parse_error"),
        ("out of memory", "runtime_memory_limit"),
        ("stack overflow", "runtime_stack_limit"),
        ("syntaxerror", "runtime_syntax_error"),
        ("referenceerror", "runtime_reference_error"),
        ("typeerror", "runtime_type_error"),
        ("internalerror", "runtime_internal_error"),
        ("evalerror", "runtime_eval_error"),
    ):
        if marker in message:
            return reason
    return "runtime_error"


@register_provider
class IllucetQuickJSJCP(EJSBaseJCP, BuiltinIEContentProvider):
    """Runs the official EJS bundle inside the statically linked QuickJS."""

    PROVIDER_NAME = "illucet-quickjs"
    PROVIDER_VERSION = "1"
    JS_RUNTIME_NAME = "illucet-quickjs"
    QUICKJS_MEMORY_LIMIT = 256 * 1024 * 1024
    QUICKJS_STACK_LIMIT = 2 * 1024 * 1024
    QUICKJS_TIMEOUT_MILLISECONDS = 30_000
    QUICKJS_OUTPUT_LIMIT = 8 * 1024 * 1024

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        _increment_diagnostic("provider_constructed_count")

    def is_available(self, /) -> bool:
        try:
            _assert_runtime_contract()
            if not self._available:
                raise IllucetProviderFailure(
                    "Illucet's pinned EJS assets are unavailable.",
                    reason="ejs_assets_unavailable",
                )
            _record_ejs_hashes(self)
            _record_provider_available()
            return True
        except (IllucetProviderCancelled, IllucetProviderFailure):
            _increment_diagnostic("provider_failure_count")
            raise
        except Exception as error:
            _increment_diagnostic("provider_failure_count")
            raise IllucetProviderFailure(
                "Illucet JavaScript provider availability check failed: "
                f"{type(error).__name__}",
                reason="provider_availability_error",
            ) from None

    def bulk_solve(self, requests: list[JsChallengeRequest]):
        requests = list(requests)
        _record_challenge_requests(requests)
        try:
            responses = list(super().bulk_solve(requests))

            remaining_requests = list(requests)
            if len(responses) != len(remaining_requests):
                raise IllucetProviderFailure(
                    "Illucet JavaScript challenge provider returned "
                    "incomplete responses.",
                    reason="incomplete_response_count",
                )

            for provider_response in responses:
                if not validate_provider_response(provider_response):
                    raise IllucetProviderFailure(
                        "Illucet JavaScript challenge provider returned an "
                        "invalid response.",
                        reason="invalid_provider_response",
                    )
                if provider_response.error is not None:
                    raise IllucetProviderFailure(
                        "Illucet JavaScript challenge solver returned an "
                        "error response.",
                        reason="solver_response_error",
                    )
                if provider_response.response is None:
                    raise IllucetProviderFailure(
                        "Illucet JavaScript challenge response was missing.",
                        reason="missing_provider_response",
                    )
                if (
                    provider_response.response.type
                    is not provider_response.request.type
                ):
                    raise IllucetProviderFailure(
                        "Illucet JavaScript challenge response type did not "
                        "match its request.",
                        reason="challenge_type_mismatch",
                    )
                if validate_response(
                    provider_response.response,
                    provider_response.request,
                ) is not True:
                    raise IllucetProviderFailure(
                        "Illucet JavaScript challenge response failed "
                        "semantic validation.",
                        reason="semantic_validation_failure",
                    )
                try:
                    remaining_requests.remove(provider_response.request)
                except ValueError:
                    raise IllucetProviderFailure(
                        "Illucet JavaScript challenge provider returned an "
                        "unknown response.",
                        reason="unknown_provider_response",
                    ) from None

            if remaining_requests:
                raise IllucetProviderFailure(
                    "Illucet JavaScript challenge provider left requests "
                    "unsolved.",
                    reason="unsolved_requests",
                )
            _record_challenge_responses(responses)
        except (IllucetProviderCancelled, IllucetProviderFailure):
            _increment_diagnostic("provider_failure_count")
            raise
        except Exception as error:
            _increment_diagnostic("provider_failure_count")
            raise IllucetProviderFailure(
                f"Illucet JavaScript challenge provider failed: "
                f"{type(error).__name__}",
                reason="solver_exception",
            ) from None

        yield from responses

    def _run_js_runtime(self, stdin: str, /) -> str:
        _increment_diagnostic("runtime_call_count")
        _record_ejs_hashes(self)
        try:
            return _illucet_native.quickjs_evaluate(
                stdin,
                self.QUICKJS_MEMORY_LIMIT,
                self.QUICKJS_STACK_LIMIT,
                self.QUICKJS_TIMEOUT_MILLISECONDS,
                self.QUICKJS_OUTPUT_LIMIT,
            )
        except InterruptedError:
            _increment_diagnostic("runtime_error_count")
            _increment_diagnostic("runtime_cancellation_count")
            raise IllucetProviderCancelled(
                "Illucet JavaScript challenge evaluation was cancelled."
            ) from None
        except TimeoutError as error:
            _increment_diagnostic("runtime_error_count")
            _increment_diagnostic("runtime_timeout_count")
            raise IllucetProviderFailure(
                f"Illucet JavaScript challenge evaluation failed: "
                f"{type(error).__name__}",
                reason="runtime_timeout",
            ) from None
        except (OverflowError, RuntimeError) as error:
            _increment_diagnostic("runtime_error_count")
            raise IllucetProviderFailure(
                f"Illucet JavaScript challenge evaluation failed: "
                f"{type(error).__name__}",
                reason=_classify_runtime_failure(error),
            ) from None


@register_preference(IllucetQuickJSJCP)
def illucet_preference(
    provider: JsChallengeProvider,
    requests: list[JsChallengeRequest],
) -> int:
    del provider, requests
    return 10_000


def contract_details() -> dict[str, object]:
    from yt_dlp.extractor.youtube.jsc._registry import _jsc_providers

    return {
        "ejs_version": ejs_version,
        "provider_key": IllucetQuickJSJCP.PROVIDER_KEY,
        "provider_registered": (
            _jsc_providers.value.get(IllucetQuickJSJCP.PROVIDER_KEY)
            is IllucetQuickJSJCP
        ),
        "quickjs_version": _illucet_native.quickjs_version(),
        "yt_dlp_version": ytdlp_version,
        "ytdlp_version": ytdlp_version,
    }


class _ProofLogger:
    prefix = "illucet-proof"
    LogLevel = IEContentProviderLogger.LogLevel
    log_level = LogLevel.INFO

    def __init__(self) -> None:
        self.messages: list[str] = []

    def _record(self, message: str, **kwargs: object) -> None:
        del kwargs
        self.messages.append(message)

    def trace(self, message: str, **kwargs: object) -> None:
        self._record(message, **kwargs)

    def debug(self, message: str, **kwargs: object) -> None:
        self._record(message, **kwargs)

    def info(self, message: str, **kwargs: object) -> None:
        self._record(message, **kwargs)

    def warning(self, message: str, **kwargs: object) -> None:
        self._record(message, **kwargs)

    def error(self, message: str, **kwargs: object) -> None:
        self._record(message, **kwargs)


class _ProofInfoExtractor:
    def get_param(self, name: str, default: object = None) -> object:
        del name
        return default

    def report_warning(self, message: str, **kwargs: object) -> None:
        raise JsChallengeProviderError(message)


def run_initialized_provider_smoke() -> dict[str, object]:
    """Exercise initialization, script verification, construction, and C API."""

    provider = IllucetQuickJSJCP(
        _ProofInfoExtractor(),
        _ProofLogger(),
        {},
    )
    available = provider.is_available()
    library = provider._lib_script
    core = provider._core_script
    stdin = provider._construct_stdin("", True, [])
    output = provider._run_js_runtime(stdin)
    return {
        **contract_details(),
        "available": available,
        "core_code": core.code,
        "core_hash": core.hash,
        "library_code": library.code,
        "library_hash": library.hash,
        "output": output,
    }


def run_fail_closed_director_smoke() -> dict[str, object]:
    """Prove invalid provider outcomes cannot reach yt-dlp's fallback path."""

    request = JsChallengeRequest(
        JsChallengeType.N,
        NChallengeInput(
            "https://signed.example/player?token=secret",
            ["secret-challenge"],
        ),
        "proof-video",
    )
    signature_request = JsChallengeRequest(
        JsChallengeType.SIG,
        SigChallengeInput(
            "https://signed.example/player?token=secret",
            ["secret-signature"],
        ),
        "proof-video",
    )

    class _ValidProofJCP(IllucetQuickJSJCP):
        def _real_bulk_solve(self, requests: list[JsChallengeRequest]):
            for current in requests:
                yield JsChallengeProviderResponse(
                    current,
                    JsChallengeResponse(
                        current.type,
                        NChallengeOutput(
                            {"secret-challenge": "valid-proof-result"}
                        ),
                    ),
                )

    class _ErrorResponseProofJCP(IllucetQuickJSJCP):
        def _real_bulk_solve(self, requests: list[JsChallengeRequest]):
            for current in requests:
                yield JsChallengeProviderResponse(
                    current,
                    None,
                    "https://leak.invalid?token=secret-response",
                )

    class _MalformedResponseProofJCP(IllucetQuickJSJCP):
        def _real_bulk_solve(self, requests: list[JsChallengeRequest]):
            del requests
            yield object()

    class _SemanticValidationExceptionProofJCP(IllucetQuickJSJCP):
        def _real_bulk_solve(self, requests: list[JsChallengeRequest]):
            for current in requests:
                yield JsChallengeProviderResponse(
                    current,
                    JsChallengeResponse(
                        current.type,
                        NChallengeOutput(None),
                    ),
                )

    class _SemanticSignatureExceptionProofJCP(IllucetQuickJSJCP):
        def _real_bulk_solve(self, requests: list[JsChallengeRequest]):
            for current in requests:
                yield JsChallengeProviderResponse(
                    current,
                    JsChallengeResponse(
                        current.type,
                        SigChallengeOutput(None),
                    ),
                )

    class _MissingResponseProofJCP(IllucetQuickJSJCP):
        def _real_bulk_solve(self, requests: list[JsChallengeRequest]):
            del requests
            yield from ()

    class _RuntimeFailureProofJCP(IllucetQuickJSJCP):
        def _real_bulk_solve(self, requests: list[JsChallengeRequest]):
            del requests
            raise RuntimeError(
                "https://leak.invalid?token=secret-runtime"
            )
            yield from ()

    def exercise(
        provider_type: type[IllucetQuickJSJCP],
        *,
        expect_failure: bool,
        challenge_request: JsChallengeRequest = request,
    ) -> tuple[bool, list[str]]:
        provider_logger = _ProofLogger()
        director_logger = _ProofLogger()
        provider = provider_type(
            _ProofInfoExtractor(),
            provider_logger,
            {},
        )
        director = JsChallengeRequestDirector(director_logger)
        director.register_provider(provider)
        try:
            results = director.bulk_solve([challenge_request])
        except IllucetProviderFailure:
            return expect_failure, provider_logger.messages + director_logger.messages
        return (
            not expect_failure and len(results) == 1,
            provider_logger.messages + director_logger.messages,
        )

    case_results: dict[str, bool] = {}
    messages: list[str] = []
    for name, provider_type, expect_failure in (
        ("valid", _ValidProofJCP, False),
        ("response_error", _ErrorResponseProofJCP, True),
        ("malformed_response", _MalformedResponseProofJCP, True),
        (
            "semantic_validation_exception",
            _SemanticValidationExceptionProofJCP,
            True,
        ),
        ("missing_response", _MissingResponseProofJCP, True),
        ("runtime_failure", _RuntimeFailureProofJCP, True),
    ):
        case_results[name], case_messages = exercise(
            provider_type,
            expect_failure=expect_failure,
        )
        messages.extend(case_messages)

    (
        case_results["semantic_signature_validation_exception"],
        case_messages,
    ) = exercise(
        _SemanticSignatureExceptionProofJCP,
        expect_failure=True,
        challenge_request=signature_request,
    )
    messages.extend(case_messages)

    global EXPECTED_QUICKJS_VERSION
    expected_quickjs_version = EXPECTED_QUICKJS_VERSION
    try:
        EXPECTED_QUICKJS_VERSION = "proof-mismatch"
        case_results["version_mismatch"], case_messages = exercise(
            IllucetQuickJSJCP,
            expect_failure=True,
        )
        messages.extend(case_messages)
    finally:
        EXPECTED_QUICKJS_VERSION = expected_quickjs_version

    sensitive_markers = (
        "signed.example",
        "leak.invalid",
        "secret-challenge",
        "secret-response",
        "secret-runtime",
        "secret-signature",
        "token=secret",
    )
    return {
        "all_cases_passed": all(case_results.values()),
        "case_results": case_results,
        "sensitive_log_found": any(
            marker in message
            for message in messages
            for marker in sensitive_markers
        ),
    }
