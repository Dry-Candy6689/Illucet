"""Request-local yt-dlp PO-token handoff. Swift runs WebKit off the Python queue."""
from contextvars import ContextVar
import json
import re
import time

from yt_dlp.extractor.youtube.pot._provider import BuiltinIEContentProvider
from yt_dlp.extractor.youtube.pot._registry import _pot_memory_cache
from yt_dlp.extractor.youtube.pot.provider import (
    PoTokenContext, PoTokenProvider, PoTokenProviderRejectedRequest, PoTokenResponse, register_provider,
)
from yt_dlp.extractor.youtube.pot.utils import get_webpo_content_binding

import _illucet_native

active_request = ContextVar("illucet_proof_request", default=None)
RECOVERABLE_CODES = {"no_compatible_format", "extraction_failed", "format_unavailable"}


def begin(request):
    # yt-dlp's default cache is process-wide. Scope it to one execution so it
    # cannot override our stricter guest/account/client/video cache keys.
    memory = _pot_memory_cache.value
    if memory.get("cache") is not None:
        with memory["lock"]:
            memory["cache"].clear()
    enabled = request.get("engine_preferences", {}).get("poTokens") == "automatic"
    records = request.get("proof_tokens", []) if enabled else []
    state = {"records": records if isinstance(records, list) and len(records) <= 3 else [], "pending": [],
             "authenticated": "account_cookies" in request,
             "transport_proof": request.get("verify_local_proof") is True}
    return active_request.set(state if enabled else None)


def finish_response(response):
    state = active_request.get()
    if not state or not state["pending"]: return response
    value = json.loads(response)
    challenge = state["pending"][0]
    if value.get("ok"):
        if not state["transport_proof"] or state["records"] or challenge["context"] != "gvs": return response
    elif value.get("error", {}).get("code") not in RECOVERABLE_CODES: return response
    value["error"] = {"code":"proof_token_required", "message":"YouTube requires a proof token for this stream.", "retryable":False}
    value["ok"] = False
    value.pop("data", None)
    value["proof_request"] = challenge
    return json.dumps(value, separators=(",", ":"))


def configure_options(options):
    state = active_request.get()
    if not state: return
    if state["transport_proof"]:
        options.setdefault("extractor_args", {}).setdefault("youtube", {})["fetch_pot"] = ["always"]
    if state["authenticated"] or not state["records"]: return
    first = state["records"][0]
    visitor = first.get("sessionBinding") if isinstance(first, dict) else None
    if isinstance(visitor, str) and 0 < len(visitor) <= 4096:
        options.setdefault("extractor_args", {}).setdefault("youtube", {})["visitor_data"] = [visitor]


@register_provider
class IllucetPTP(PoTokenProvider, BuiltinIEContentProvider):
    PROVIDER_NAME = "Illucet local"
    _SUPPORTED_CLIENTS = ("WEB", "MWEB", "WEB_EMBEDDED_PLAYER", "WEB_CREATOR", "WEB_REMIX")
    _SUPPORTED_CONTEXTS = (PoTokenContext.GVS, PoTokenContext.PLAYER, PoTokenContext.SUBS)

    def is_available(self):
        return active_request.get() is not None

    def _real_request_pot(self, request):
        state = active_request.get()
        binding, _ = get_webpo_content_binding(request, bind_to_visitor_id=True)
        client = request.innertube_context.get("client", {}).get("clientName")
        video = request.video_id
        session = (request.data_sync_id if request.is_authenticated else request.visitor_data) or ""
        if not state or request.is_authenticated != state["authenticated"] or not isinstance(video, str) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", video):
            raise PoTokenProviderRejectedRequest("Unsupported proof request")
        if not isinstance(binding, str) or not 0 < len(binding) <= 4096 or len(session) > 4096:
            raise PoTokenProviderRejectedRequest("Unsupported proof binding")
        facts = {"client":client, "context":request.context.value, "videoID":video,
                 "binding":binding, "sessionBinding":session}
        for record in state["records"]:
            if not isinstance(record, dict) or any(record.get(key) != value for key, value in facts.items()): continue
            token, expiry = record.get("token"), record.get("expires")
            if isinstance(token, str) and re.fullmatch(r"[A-Za-z0-9_=\-]{40,4096}", token) and isinstance(expiry, (int,float)) and time.time() + 10 < expiry < time.time() + 21660:
                _illucet_native.emit_json(json.dumps({"kind":"proof_token_used","payload":{"client":client,"context":request.context.value}}))
                return PoTokenResponse(token, int(expiry))
        if len(state["pending"]) < 8 and facts not in state["pending"]:
            # Optional subtitle/player requests should not displace a stream
            # token when missing formats caused the current failure.
            if request.context == PoTokenContext.GVS: state["pending"].insert(0, facts)
            else: state["pending"].append(facts)
        raise PoTokenProviderRejectedRequest("No local proof has been generated yet")
