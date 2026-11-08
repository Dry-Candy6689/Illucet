"""Secret-free metadata extraction through yt-dlp's in-process Python API."""

from __future__ import annotations

import illucet_accounts

import hashlib
import ipaddress
import itertools
import json
import math
import os
import re
import time
import uuid
from collections import OrderedDict
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from urllib.parse import parse_qs, urljoin, urlsplit, urlunsplit

import _illucet_native
import certifi
from yt_dlp import YoutubeDL, dependencies as ytdlp_dependencies
from yt_dlp.utils import (
    DownloadError,
    ExtractorError,
    GeoRestrictedError,
    UnsupportedError,
)

import illucet_ytdlp_provider

_MAX_URL_LENGTH = 4_096
_MAX_OUTPUT_BYTES = 8 * 1024 * 1024
_MAX_DESCRIPTION_CHARACTERS = 100_000
_MAX_FORMATS = 2_000
_MAX_THUMBNAILS = 100
_MAX_CHAPTERS = 10_000
_MAX_SUBTITLE_LANGUAGES = 1_000
_MAX_SUBTITLE_FORMATS = 1_000
_MAX_PLAYLIST_ENTRIES = 500
_MAX_HTTP_CHUNK_SIZE_BYTES = 256 * 1024 * 1024
_MAX_STREAM_AVAILABILITY_WAIT_SECONDS = 600
_MAX_DASH_FRAGMENTS = 2_048
_MAX_HLS_PLAN_OUTPUT_BYTES = 128 * 1024

# Worker-thread-only, anonymous extraction handoff. Serialized bytes bound memory
# and prevent callers mutating shared results. No files, credentials or URL logs.
_RECENT_TTL_SECONDS = 60
_RECENT_MAX_BYTES = 16 * 1024 * 1024
_RECENT_MAX_ENTRIES = 4
_recent_extractions: OrderedDict[str, tuple[float, str, bytes]] = OrderedDict()


def clear_recent_extractions() -> None:
    _recent_extractions.clear()


def _recent_entry(url: str, request: dict[str, Any]):
    if "account_cookies" in request:
        clear_recent_extractions()
        return None
    now = time.monotonic()
    for key, (deadline, _, _) in list(_recent_extractions.items()):
        if now >= deadline:
            del _recent_extractions[key]
    return _recent_extractions.get(url)


def _remember_extraction(url: str, request: dict[str, Any], info, result) -> None:
    if request.get("retain_for_download") is not True or "account_cookies" in request:
        return
    # Only direct media gets the transport handoff. Manifests retain their fresh
    # resolution/resource validation path. Never retain DRM or account transport.
    formats = []
    keys = ("format_id", "url", "ext", "protocol", "vcodec", "acodec",
            "filesize", "filesize_approx", "downloader_options", "available_at")
    for raw in info.get("formats", [])[:_MAX_FORMATS]:
        if not isinstance(raw, dict) or raw.get("protocol") not in {"http", "https"} or raw.get("has_drm"):
            continue
        try:
            illucet_accounts.validate_media_transport(raw)
            item = {key: raw[key] for key in keys if key in raw}
            item["url"] = _resolved_media_url(raw.get("url"))
            item["http_headers"] = _resolved_headers(raw.get("http_headers"))
            # Keep only the bounded, supported downloader hint.
            item["downloader_options"] = {"http_chunk_size": _http_chunk_size_hint(raw.get("downloader_options"))}
            formats.append(item)
        except SafeExtractionFailure:
            continue
    if not formats:
        return
    token = uuid.uuid4().hex
    encoded = json.dumps({"extraction": result, "info": {"id": info.get("id"), "formats": formats}},
                         separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(encoded) > min(_MAX_OUTPUT_BYTES, _RECENT_MAX_BYTES):
        return
    _recent_entry(url, request)
    _recent_extractions.pop(url, None)
    while _recent_extractions and (len(_recent_extractions) >= _RECENT_MAX_ENTRIES
            or sum(len(entry[2]) for entry in _recent_extractions.values()) + len(encoded) > _RECENT_MAX_BYTES):
        _recent_extractions.popitem(last=False)
    _recent_extractions[url] = (time.monotonic() + _RECENT_TTL_SECONDS, token, encoded)
    result["reuse_token"] = token
_VIDEO_ID = re.compile(r"^[0-9A-Za-z_-]{11}$")
_PLAYLIST_ID = re.compile(r"^[0-9A-Za-z_-]{2,128}$")
_SAFE_UPLOAD_DATE = re.compile(r"^[0-9]{8}$")
_SENSITIVE_FIELD_PATTERN = (
    r"(?:"
    r"authorization|proxy[-_]?authorization|"
    r"cookie|set[-_]?cookie|"
    r"x[-_]?api[-_]?key|x[-_]?auth[-_]?token|"
    r"api[-_]?key|client[-_]?secret|password|passwd|"
    r"oauth(?:[-_]?token)?|"
    r"access[-_]?token|refresh[-_]?token|id[-_]?token|"
    r"po[-_]?token|token|signature|lsig|nsig|sig"
    r")"
)
_SENSITIVE_HEADER_PATTERN = (
    r"(?:"
    r"authorization|proxy[-_]?authorization|"
    r"cookie|set[-_]?cookie|"
    r"x[-_]?api[-_]?key|x[-_]?auth[-_]?token"
    r")"
)
_SENSITIVE_QUERY_FIELD_PATTERN = (
    r"(?:"
    r"authorization|cookie|"
    r"api[-_]?key|client[-_]?secret|"
    r"oauth(?:[-_]?token)?|"
    r"access[-_]?token|refresh[-_]?token|id[-_]?token|"
    r"po[-_]?token|token|signature|lsig|nsig|sig|n"
    r")"
)
_SENSITIVE_VALUE_PATTERN = (
    r"(?:"
    r'"(?:\\[^\r\n]|[^"\\\r\n])*(?:"|(?=\r?$))|'
    r"'(?:\\[^\r\n]|[^'\\\r\n])*(?:'|(?=\r?$))|"
    r"(?:(?:bearer|basic)\b[^\r\n]*)|"
    r"[^\s&;,}\]\"']+"
    r")"
)
_SECRET_ASSIGNMENT = re.compile(
    (
        r"(?P<prefix>"
        r"(?<![?&#\w-])"
        r"[\"']?"
        + _SENSITIVE_FIELD_PATTERN
        + r"[\"']?\s*[:=]\s*"
        r")"
        + _SENSITIVE_VALUE_PATTERN
    ),
    re.IGNORECASE | re.MULTILINE,
)
_SECRET_HEADER = re.compile(
    (
        r"(?P<prefix>"
        r"(?<![?&#\w-])"
        + _SENSITIVE_HEADER_PATTERN
        + r"\s*:\s*"
        r")[^\r\n]*"
    ),
    re.IGNORECASE | re.MULTILINE,
)
_SECRET_WHOLE_LINE_ASSIGNMENT = re.compile(
    (
        r"(?P<prefix>"
        r"(?<![?&#\w-])"
        + _SENSITIVE_HEADER_PATTERN
        + r"\s*=\s*"
        r")[^\r\n]*"
    ),
    re.IGNORECASE | re.MULTILINE,
)
_SECRET_QUERY_VALUE = re.compile(
    (
        r"(?P<prefix>"
        r"(?:[?&#]|&amp;)"
        + _SENSITIVE_QUERY_FIELD_PATTERN
        + r"="
        r")"
        + _SENSITIVE_VALUE_PATTERN
    ),
    re.IGNORECASE | re.MULTILINE,
)
_YOUTUBE_HOSTS = frozenset(
    {
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "music.youtube.com",
        "youtu.be",
        "www.youtu.be",
        "youtube-nocookie.com",
        "www.youtube-nocookie.com",
    }
)
_YOUTUBE_THUMBNAIL_HOST_SUFFIXES = (
    ".ytimg.com",
    ".ggpht.com",
)
_MEDIA_HOST_SUFFIXES = (
    ".googlevideo.com",
)
_ALLOWED_STREAM_HEADERS = frozenset(
    {
        "accept",
        "accept-language",
        "origin",
        "referer",
        "user-agent",
        "sec-fetch-mode",
    }
)


@dataclass(frozen=True)
class SafeExtractionFailure(Exception):
    """A bounded error intended to cross the native JSON boundary."""

    code: str
    message: str
    retryable: bool = False

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True)
class _PlaylistURLIntent:
    extraction_url: str
    canonical_url: str
    playlist_id: str
    kind: str
    referenced_video_id: str | None
    input_was_shorts: bool


class _SafeLogger:
    """Counts yt-dlp diagnostics but deliberately stores no message text."""

    def __init__(self) -> None:
        self.warning_count = 0
        self.error_count = 0

    @staticmethod
    def _checkpoint() -> None:
        if _illucet_native.is_cancelled():
            raise illucet_ytdlp_provider.IllucetProviderCancelled(
                "Illucet metadata extraction was cancelled."
            )

    def debug(self, message: object) -> None:
        del message
        self._checkpoint()

    def info(self, message: object) -> None:
        del message
        self._checkpoint()

    def warning(self, message: object) -> None:
        del message
        self.warning_count += 1
        self._checkpoint()

    def error(self, message: object) -> None:
        del message
        self.error_count += 1
        self._checkpoint()


def _checkpoint() -> None:
    if _illucet_native.is_cancelled():
        raise illucet_ytdlp_provider.IllucetProviderCancelled(
            "Illucet metadata extraction was cancelled."
        )


def _bounded_text(
    value: object,
    *,
    maximum: int,
    required: bool = False,
) -> str | None:
    if not isinstance(value, str):
        if required:
            raise SafeExtractionFailure(
                "invalid_metadata",
                "The extractor returned incomplete metadata.",
            )
        return None
    value = value.replace("\x00", "\N{REPLACEMENT CHARACTER}").strip()
    if not value:
        if required:
            raise SafeExtractionFailure(
                "invalid_metadata",
                "The extractor returned incomplete metadata.",
            )
        return None
    if len(value.encode("utf-8")) > maximum:
        raise SafeExtractionFailure(
            "metadata_too_large",
            "The extracted metadata exceeds Illucet's safety limit.",
        )
    return value


def _redact_text(value: object, *, maximum: int) -> str | None:
    text = _bounded_text(value, maximum=maximum)
    if text is None:
        return None
    text = _SECRET_ASSIGNMENT.sub(
        lambda match: f"{match.group('prefix')}[REDACTED]",
        text,
    )
    text = _SECRET_HEADER.sub(
        lambda match: f"{match.group('prefix')}[REDACTED]",
        text,
    )
    text = _SECRET_WHOLE_LINE_ASSIGNMENT.sub(
        lambda match: f"{match.group('prefix')}[REDACTED]",
        text,
    )
    return _SECRET_QUERY_VALUE.sub(
        lambda match: f"{match.group('prefix')}[REDACTED]",
        text,
    )


def _normalize_youtube_url(value: object) -> str:
    raw_url = _bounded_text(
        value,
        maximum=_MAX_URL_LENGTH,
        required=True,
    )
    assert raw_url is not None
    try:
        parsed = urlsplit(raw_url)
        port = parsed.port
    except (TypeError, ValueError):
        raise SafeExtractionFailure(
            "invalid_url",
            "Enter a valid YouTube media URL.",
        ) from None

    host = (parsed.hostname or "").rstrip(".").lower()
    if (
        parsed.scheme.lower() != "https"
        or not host
        or parsed.username is not None
        or parsed.password is not None
        or port not in {None, 80, 443}
    ):
        raise SafeExtractionFailure(
            "invalid_url",
            "Enter a valid HTTPS YouTube media URL.",
        )
    if host not in _YOUTUBE_HOSTS:
        raise SafeExtractionFailure(
            "unsupported_site",
            "This Stage 0 extractor supports YouTube URLs only.",
        )

    path_parts = [part for part in parsed.path.split("/") if part]
    video_id: str | None = None
    route = "watch"
    if host in {"youtu.be", "www.youtu.be"}:
        if path_parts:
            video_id = path_parts[0]
    elif parsed.path.rstrip("/") == "/watch":
        try:
            video_id = parse_qs(
                parsed.query,
                keep_blank_values=False,
                max_num_fields=64,
            ).get("v", [None])[0]
        except ValueError:
            raise SafeExtractionFailure(
                "invalid_url",
                "The YouTube URL contains too many parameters.",
            ) from None
    elif len(path_parts) >= 2 and path_parts[0] in {
        "embed",
        "live",
        "shorts",
        "v",
    }:
        route = path_parts[0]
        video_id = path_parts[1]
    elif path_parts and path_parts[0] in {"playlist", "channel", "user"}:
        raise SafeExtractionFailure(
            "playlist_confirmation_required",
            "Choose a specific video before running this Stage 0 test.",
        )

    if not isinstance(video_id, str) or not _VIDEO_ID.fullmatch(video_id):
        raise SafeExtractionFailure(
            "url_does_not_identify_media",
            "The URL does not identify a supported YouTube video.",
        )

    if route in {"shorts", "live"}:
        return f"https://www.youtube.com/{route}/{video_id}"
    return f"https://www.youtube.com/watch?v={video_id}"


def _normalize_youtube_playlist_url(value: object) -> _PlaylistURLIntent:
    raw_url = _bounded_text(
        value,
        maximum=_MAX_URL_LENGTH,
        required=True,
    )
    assert raw_url is not None
    try:
        parsed = urlsplit(raw_url)
        port = parsed.port
        query = parse_qs(
            parsed.query,
            keep_blank_values=False,
            max_num_fields=64,
        )
    except (TypeError, ValueError):
        raise SafeExtractionFailure(
            "invalid_url",
            "Enter a valid YouTube playlist URL.",
        ) from None

    host = (parsed.hostname or "").rstrip(".").lower()
    if (
        parsed.scheme.lower() != "https"
        or not host
        or parsed.username is not None
        or parsed.password is not None
        or port not in {None, 80, 443}
    ):
        raise SafeExtractionFailure(
            "invalid_url",
            "Enter a valid HTTPS YouTube playlist URL.",
        )
    if host not in _YOUTUBE_HOSTS:
        raise SafeExtractionFailure(
            "unsupported_site",
            "Playlist analysis currently supports YouTube URLs only.",
        )

    parts = [part for part in parsed.path.split("/") if part]
    if "list" not in query and host not in {"youtu.be", "www.youtu.be"} and parts and (
        parts[0].startswith("@") or parts[0] in {"channel", "c", "user"}
    ):
        base_count = 1 if parts[0].startswith("@") else 2
        if len(parts) in {base_count, base_count + 1} and all(
            re.fullmatch(r"[A-Za-z0-9_@.\-]{1,128}", p) for p in parts[:base_count]
        ):
            tab = parts[base_count] if len(parts) > base_count else "videos"
            kinds = {"videos": "creatorUploads", "shorts": "creatorShorts", "streams": "creatorReplays"}
            if tab in kinds:
                path = "/".join(parts[:base_count]) + "/" + tab
                canonical = "https://www.youtube.com/" + path
                return _PlaylistURLIntent(extraction_url=canonical, canonical_url=canonical,
                    playlist_id=path, kind=kinds[tab], referenced_video_id=None,
                    input_was_shorts=tab == "shorts")

    playlist_id = query.get("list", [None])[0]
    if (
        not isinstance(playlist_id, str)
        or not _PLAYLIST_ID.fullmatch(playlist_id)
    ):
        raise SafeExtractionFailure(
            "url_does_not_identify_playlist",
            "The URL does not identify a supported YouTube playlist.",
        )

    path_parts = [part for part in parsed.path.split("/") if part]
    referenced_video_id: str | None = None
    input_was_shorts = False
    if host in {"youtu.be", "www.youtu.be"}:
        if path_parts:
            referenced_video_id = path_parts[0]
    elif parsed.path.rstrip("/") == "/watch":
        referenced_video_id = query.get("v", [None])[0]
    elif len(path_parts) >= 2 and path_parts[0] in {
        "embed",
        "live",
        "shorts",
        "v",
    }:
        input_was_shorts = path_parts[0] == "shorts"
        referenced_video_id = path_parts[1]
    elif parsed.path.rstrip("/") != "/playlist":
        raise SafeExtractionFailure(
            "url_does_not_identify_playlist",
            "The URL does not identify a supported YouTube playlist.",
        )

    if not isinstance(referenced_video_id, str) or not _VIDEO_ID.fullmatch(
        referenced_video_id
    ):
        referenced_video_id = None

    if playlist_id in {"WL", "LL"}:
        kind = "privateCollection"
    elif playlist_id.startswith("RD"):
        kind = "mix"
    elif input_was_shorts:
        kind = "shorts"
    else:
        kind = "playlist"

    canonical_url = (
        f"https://www.youtube.com/playlist?list={playlist_id}"
    )
    extraction_url = canonical_url
    if referenced_video_id is not None:
        extraction_url = (
            "https://www.youtube.com/watch?"
            f"v={referenced_video_id}&list={playlist_id}"
        )
    return _PlaylistURLIntent(
        extraction_url=extraction_url,
        canonical_url=canonical_url,
        playlist_id=playlist_id,
        kind=kind,
        referenced_video_id=referenced_video_id,
        input_was_shorts=input_was_shorts,
    )


def _safe_thumbnail_url(value: object) -> str | None:
    raw_url = _bounded_text(value, maximum=_MAX_URL_LENGTH)
    if raw_url is None:
        return None
    try:
        parsed = urlsplit(raw_url)
        port = parsed.port
    except (TypeError, ValueError):
        return None
    host = (parsed.hostname or "").rstrip(".").lower()
    if (
        parsed.scheme.lower() != "https"
        or not host
        or parsed.username is not None
        or parsed.password is not None
        or port not in {None, 80, 443}
        or not any(
            host.endswith(suffix)
            for suffix in _YOUTUBE_THUMBNAIL_HOST_SUFFIXES
        )
    ):
        return None
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if (
        host == "localhost"
        or host.endswith(".localhost")
        or (
            address is not None
            and (
                address.is_private
                or address.is_loopback
                or address.is_link_local
                or address.is_reserved
                or address.is_unspecified
            )
        )
    ):
        return None
    return urlunsplit(("https", host, parsed.path, "", ""))


def _safe_subtitle_text(value: object, *, maximum: int) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.replace("\x00", "\N{REPLACEMENT CHARACTER}").strip()
    if not value or len(value.encode("utf-8")) > maximum:
        return None
    return _redact_text(value, maximum=maximum)


def _safe_subtitle_url(value: object) -> str | None:
    if not isinstance(value, str) or value != value.strip():
        return None
    if (
        not value
        or len(value.encode("utf-8")) > _MAX_URL_LENGTH
        or "\\" in value
        or any(character.isspace() or ord(character) < 0x20 for character in value)
    ):
        return None
    try:
        parsed = urlsplit(value)
        port = parsed.port
        host = parsed.hostname
    except (TypeError, ValueError):
        return None
    if (
        parsed.scheme.lower() != "https"
        or not host
        or parsed.username is not None
        or parsed.password is not None
        or port == 0
    ):
        return None
    return value


def _subtitle_identity(prefix: str, *components: object) -> str:
    canonical = json.dumps(
        components,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return f"{prefix}-{hashlib.sha256(canonical).hexdigest()[:24]}"


def _finite_number(
    value: object,
    *,
    integral: bool = False,
) -> float | int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if not math.isfinite(number) or number < 0:
        return None
    if integral:
        if not number.is_integer() or number > 9_223_372_036_854_775_807:
            return None
        return int(number)
    return number


def _codec(value: object) -> str | None:
    codec = _bounded_text(value, maximum=128)
    if codec is None or codec.lower() == "none":
        return None
    return codec


def _source_type(protocol: str | None) -> str:
    lowered = (protocol or "").lower()
    if "m3u8" in lowered or "hls" in lowered:
        return "hls"
    if "dash" in lowered or "mpd" in lowered:
        return "dash"
    if lowered in {"http", "https"}:
        return "direct_http"
    return "other"


def _sanitize_format(raw_format: object) -> dict[str, object] | None:
    if not isinstance(raw_format, dict) or raw_format.get("has_drm") is True:
        return None
    format_id = _bounded_text(
        raw_format.get("format_id"),
        maximum=256,
    )
    source_url = raw_format.get("url")
    if format_id is None or not isinstance(source_url, str) or not source_url:
        return None

    video_codec = _codec(raw_format.get("vcodec"))
    audio_codec = _codec(raw_format.get("acodec"))
    has_video = video_codec is not None
    has_audio = audio_codec is not None
    if not has_video and not has_audio:
        return None

    protocol = _bounded_text(raw_format.get("protocol"), maximum=64)
    dynamic_range = _bounded_text(
        raw_format.get("dynamic_range"),
        maximum=64,
    )
    is_hdr = (
        dynamic_range is not None
        and dynamic_range.lower() not in {"sdr", "none", "unknown"}
    )
    return {
        "format_id": format_id,
        "format_note": _redact_text(
            raw_format.get("format_note"),
            maximum=512,
        ),
        "extension": _bounded_text(raw_format.get("ext"), maximum=32),
        "container": _bounded_text(
            raw_format.get("container"),
            maximum=64,
        ),
        "video_codec": video_codec,
        "audio_codec": audio_codec,
        "width": _finite_number(raw_format.get("width"), integral=True),
        "height": _finite_number(raw_format.get("height"), integral=True),
        "resolution": _bounded_text(
            raw_format.get("resolution"),
            maximum=64,
        ),
        "frames_per_second": _finite_number(raw_format.get("fps")),
        "dynamic_range": dynamic_range,
        "is_hdr": is_hdr,
        "audio_bitrate_kbps": _finite_number(raw_format.get("abr")),
        "video_bitrate_kbps": _finite_number(raw_format.get("vbr")),
        "total_bitrate_kbps": _finite_number(raw_format.get("tbr")),
        "exact_file_size_bytes": _finite_number(
            raw_format.get("filesize"),
            integral=True,
        ),
        "approximate_file_size_bytes": _finite_number(
            raw_format.get("filesize_approx"),
            integral=True,
        ),
        "has_video": has_video,
        "has_audio": has_audio,
        "protocol": protocol,
        "source_type": _source_type(protocol),
        "language": _bounded_text(
            raw_format.get("language"),
            maximum=128,
        ),
    }


def _sanitize_formats(raw_formats: object) -> list[dict[str, object]]:
    if not isinstance(raw_formats, (list, tuple)):
        raise SafeExtractionFailure(
            "no_compatible_format",
            "No usable media formats were returned.",
        )
    if len(raw_formats) > _MAX_FORMATS:
        raise SafeExtractionFailure(
            "metadata_too_large",
            "The format list exceeds Illucet's safety limit.",
        )
    # extract_info returns formats in yt-dlp preference order, worst to best.
    # Preserve that ordering without exporting transport URLs or sort internals.
    formats = []
    for rank, raw_format in enumerate(raw_formats):
        sanitized = _sanitize_format(raw_format)
        if sanitized is not None:
            sanitized["extractor_preference_rank"] = rank
            formats.append(sanitized)
    if not formats:
        raise SafeExtractionFailure(
            "no_compatible_format",
            "No non-DRM audio or video formats are available.",
        )
    return formats


def _sanitize_thumbnails(raw_thumbnails: object) -> list[dict[str, object]]:
    if not isinstance(raw_thumbnails, (list, tuple)):
        return []
    if len(raw_thumbnails) > _MAX_THUMBNAILS:
        raise SafeExtractionFailure(
            "metadata_too_large",
            "The thumbnail list exceeds Illucet's safety limit.",
        )
    thumbnails: list[dict[str, object]] = []
    seen: set[tuple[object, ...]] = set()
    for raw_thumbnail in raw_thumbnails:
        if not isinstance(raw_thumbnail, dict):
            continue
        url = _safe_thumbnail_url(raw_thumbnail.get("url"))
        if url is None:
            continue
        thumbnail = {
            "url": url,
            "width": _finite_number(
                raw_thumbnail.get("width"),
                integral=True,
            ),
            "height": _finite_number(
                raw_thumbnail.get("height"),
                integral=True,
            ),
            "id": _bounded_text(raw_thumbnail.get("id"), maximum=256),
        }
        key = tuple(thumbnail.values())
        if key not in seen:
            seen.add(key)
            thumbnails.append(thumbnail)
    return thumbnails


def _sanitize_chapters(raw_chapters: object) -> list[dict[str, object]]:
    if not isinstance(raw_chapters, (list, tuple)):
        return []
    if len(raw_chapters) > _MAX_CHAPTERS:
        raise SafeExtractionFailure(
            "metadata_too_large",
            "The chapter list exceeds Illucet's safety limit.",
        )
    chapters: list[dict[str, object]] = []
    for raw_chapter in raw_chapters:
        if not isinstance(raw_chapter, dict):
            continue
        start = _finite_number(raw_chapter.get("start_time"))
        if start is None:
            continue
        chapters.append(
            {
                "title": _redact_text(
                    raw_chapter.get("title"),
                    maximum=1_024,
                ),
                "start_time_seconds": start,
                "end_time_seconds": _finite_number(
                    raw_chapter.get("end_time")
                ),
            }
        )
    return chapters


def _subtitle_records(
    raw_subtitles: object,
    *,
    automatic: bool,
) -> list[dict[str, object]]:
    if not isinstance(raw_subtitles, dict):
        return []
    if len(raw_subtitles) > _MAX_SUBTITLE_LANGUAGES:
        raise SafeExtractionFailure(
            "metadata_too_large",
            "The subtitle-language list exceeds Illucet's safety limit.",
        )
    records: list[dict[str, object]] = []
    for raw_language, raw_formats in raw_subtitles.items():
        language = _safe_subtitle_text(raw_language, maximum=128)
        if language is None or not isinstance(raw_formats, (list, tuple)):
            continue
        if len(raw_formats) > _MAX_SUBTITLE_FORMATS:
            raise SafeExtractionFailure(
                "metadata_too_large",
                "A subtitle format list exceeds Illucet's safety limit.",
            )
        track_id = _subtitle_identity(
            "subtitle",
            "automatic" if automatic else "manual",
            language,
        )
        formats: list[dict[str, object]] = []
        name: str | None = None
        seen_urls: set[str] = set()
        descriptor_occurrences: dict[tuple[str, str], int] = {}
        for raw_format in raw_formats:
            if not isinstance(raw_format, dict):
                continue
            url = _safe_subtitle_url(raw_format.get("url"))
            if url is None or url in seen_urls:
                continue
            seen_urls.add(url)
            extension = _safe_subtitle_text(
                raw_format.get("ext"),
                maximum=32,
            )
            format_name = _safe_subtitle_text(
                raw_format.get("name"),
                maximum=256,
            )
            if name is None:
                name = format_name
            descriptor = (extension or "", format_name or "")
            occurrence = descriptor_occurrences.get(descriptor, 0)
            descriptor_occurrences[descriptor] = occurrence + 1
            # Every subtitle delivery starts from WebVTT. Keep the original
            # descriptor numbering and track name so saved selections retain
            # their identities, but do not export unusable transport variants.
            if (extension or "").lower() != "vtt":
                continue
            formats.append(
                {
                    "format_id": _subtitle_identity(
                        "subtitle-format",
                        track_id,
                        extension,
                        format_name,
                        occurrence,
                    ),
                    "url": url,
                    "extension": extension,
                    "name": format_name,
                }
            )
        if not formats:
            continue
        records.append(
            {
                "track_id": track_id,
                "language": language,
                "name": name,
                "automatic": automatic,
                "formats": formats,
            }
        )
    return records


def _upload_date(value: object) -> str | None:
    upload_date = _bounded_text(value, maximum=16)
    if upload_date is None or not _SAFE_UPLOAD_DATE.fullmatch(upload_date):
        return None
    try:
        return datetime.strptime(upload_date, "%Y%m%d").date().isoformat()
    except ValueError:
        return None


def sanitize_metadata(
    info: object,
    *,
    normalized_input_url: str,
) -> dict[str, object]:
    """Project a raw yt-dlp info dict onto Illucet's stable safe schema."""

    if not isinstance(info, dict):
        raise SafeExtractionFailure(
            "invalid_metadata",
            "The extractor did not return a media record.",
        )
    if info.get("_type") in {"playlist", "multi_video"} or info.get(
        "entries"
    ) is not None:
        raise SafeExtractionFailure(
            "playlist_confirmation_required",
            "Playlist downloads require explicit item selection.",
        )

    video_id = _bounded_text(info.get("id"), maximum=256, required=True)
    assert video_id is not None
    if not _VIDEO_ID.fullmatch(video_id):
        raise SafeExtractionFailure(
            "invalid_metadata",
            "The extractor returned an invalid YouTube video identifier.",
        )
    title = _redact_text(info.get("title"), maximum=512)
    if title is None:
        raise SafeExtractionFailure(
            "invalid_metadata",
            "The extractor returned no media title.",
        )

    input_video_id = normalized_input_url.rsplit("/", 1)[-1]
    if "watch?v=" in normalized_input_url:
        input_video_id = normalized_input_url.rsplit("=", 1)[-1]
    if input_video_id != video_id:
        raise SafeExtractionFailure(
            "verification_mismatch",
            "The extracted video identifier does not match the requested URL.",
        )

    subtitles = _subtitle_records(
        info.get("subtitles"),
        automatic=False,
    )
    subtitles.extend(
        _subtitle_records(
            info.get("automatic_captions"),
            automatic=True,
        )
    )
    formats = _sanitize_formats(info.get("formats"))
    metadata = {
        "canonical_url": (
            f"https://www.youtube.com/watch?v={video_id}"
        ),
        "video_id": video_id,
        "title": title,
        "channel": _redact_text(info.get("channel"), maximum=512),
        "uploader": _redact_text(info.get("uploader"), maximum=512),
        "duration_seconds": _finite_number(info.get("duration")),
        "upload_date": _upload_date(info.get("upload_date")),
        "description": _redact_text(
            info.get("description"),
            maximum=_MAX_DESCRIPTION_CHARACTERS,
        ),
        "is_live": bool(info.get("is_live") is True),
        "live_status": _bounded_text(
            info.get("live_status"),
            maximum=64,
        ),
        "thumbnails": _sanitize_thumbnails(info.get("thumbnails")),
        "chapters": _sanitize_chapters(info.get("chapters")),
        "subtitles": subtitles,
        "formats": formats,
    }
    if len(
        json.dumps(
            metadata,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    ) > _MAX_OUTPUT_BYTES:
        raise SafeExtractionFailure(
            "metadata_too_large",
            "The extracted metadata exceeds Illucet's output limit.",
        )
    return metadata


def _playlist_availability(
    raw_entry: object,
    *,
    video_id: str | None,
    title: str | None,
) -> str:
    if not isinstance(raw_entry, dict):
        return "unavailable"
    lowered_title = (title or "").casefold()
    raw_availability = _bounded_text(
        raw_entry.get("availability"),
        maximum=64,
    )
    lowered_availability = (raw_availability or "").casefold()
    if "deleted video" in lowered_title:
        return "deleted"
    if (
        "private video" in lowered_title
        or lowered_availability
        in {
            "needs_auth",
            "premium_only",
            "subscriber_only",
        }
    ):
        return "privateVideo"
    if (
        video_id is None
        or raw_entry.get("is_unavailable") is True
        or lowered_availability in {"unavailable", "blocked"}
    ):
        return "unavailable"
    return "available"


def _playlist_thumbnail(raw_entry: object) -> str | None:
    if not isinstance(raw_entry, dict):
        return None
    direct = _safe_thumbnail_url(raw_entry.get("thumbnail"))
    if direct is not None:
        return direct
    thumbnails = raw_entry.get("thumbnails")
    if not isinstance(thumbnails, (list, tuple)):
        return None
    for thumbnail in reversed(thumbnails[:_MAX_THUMBNAILS]):
        if not isinstance(thumbnail, dict):
            continue
        safe_url = _safe_thumbnail_url(thumbnail.get("url"))
        if safe_url is not None:
            return safe_url
    return None


def _playlist_reported_count(info: dict[str, object]) -> int | None:
    for key in ("playlist_count", "n_entries", "entry_count"):
        value = _finite_number(info.get(key), integral=True)
        if isinstance(value, int):
            return value
    return None


def _bounded_playlist_entries(
    value: object,
    *,
    maximum_entries: int,
) -> tuple[list[object], bool]:
    if value is None:
        return [], False
    if isinstance(value, (str, bytes, dict)):
        raise SafeExtractionFailure(
            "invalid_metadata",
            "The extractor returned an invalid playlist entry list.",
        )
    try:
        iterator = iter(value)
    except TypeError:
        raise SafeExtractionFailure(
            "invalid_metadata",
            "The extractor returned an invalid playlist entry list.",
        ) from None

    entries: list[object] = []
    for raw_entry in iterator:
        _checkpoint()
        entries.append(raw_entry)
        if len(entries) > maximum_entries:
            return entries[:maximum_entries], True
    return entries, False


def _sanitize_playlist(
    info: object,
    *,
    intent: _PlaylistURLIntent,
    maximum_entries: int,
) -> dict[str, object]:
    if not isinstance(info, dict):
        raise SafeExtractionFailure(
            "invalid_metadata",
            "The extractor did not return a playlist record.",
        )
    raw_entries, had_sentinel = _bounded_playlist_entries(
        info.get("entries"),
        maximum_entries=maximum_entries,
    )
    entries: list[dict[str, object]] = []
    available_entry_count = 0
    all_available_entries_are_shorts = True
    for fallback_index, raw_entry in enumerate(raw_entries, start=1):
        _checkpoint()
        raw = raw_entry if isinstance(raw_entry, dict) else {}
        raw_index = _finite_number(
            raw.get("playlist_index"),
            integral=True,
        )
        index = (
            raw_index
            if isinstance(raw_index, int) and raw_index > 0
            else fallback_index
        )
        candidate_video_id = _bounded_text(raw.get("id"), maximum=256)
        video_id = (
            candidate_video_id
            if candidate_video_id is not None
            and _VIDEO_ID.fullmatch(candidate_video_id)
            else None
        )
        title = _redact_text(raw.get("title"), maximum=512)
        availability = _playlist_availability(
            raw_entry,
            video_id=video_id,
            title=title,
        )
        if intent.kind == "creatorReplays" and raw.get("live_status") != "was_live":
            availability = "unavailable"
        if title is None:
            if availability == "privateVideo":
                title = "Private video"
            elif availability == "deleted":
                title = "Deleted video"
            else:
                title = "Unavailable video"

        raw_url = _bounded_text(raw.get("url"), maximum=_MAX_URL_LENGTH)
        raw_webpage_url = _bounded_text(
            raw.get("webpage_url"),
            maximum=_MAX_URL_LENGTH,
        )
        entry_looks_short = any(
            "/shorts/" in candidate
            for candidate in (raw_url, raw_webpage_url)
            if candidate is not None
        )
        if availability == "available":
            available_entry_count += 1
            if not entry_looks_short:
                all_available_entries_are_shorts = False

        canonical_url = None
        if availability == "available" and video_id is not None:
            canonical_url = (
                f"https://www.youtube.com/watch?v={video_id}"
            )
        estimated_bytes = _finite_number(
            raw.get("filesize"),
            integral=True,
        )
        if estimated_bytes is None:
            estimated_bytes = _finite_number(
                raw.get("filesize_approx"),
                integral=True,
            )
        entries.append(
            {
                "id": f"{index}:{video_id or 'unavailable'}",
                "index": index,
                "video_id": video_id,
                "canonical_url": canonical_url,
                "title": title,
                "creator": _redact_text(
                    raw.get("channel") or raw.get("uploader"),
                    maximum=512,
                ),
                "duration_seconds": _finite_number(raw.get("duration")),
                "thumbnail_url": _playlist_thumbnail(raw),
                "estimated_bytes": estimated_bytes,
                "availability": availability,
                "upload_date": _upload_date(raw.get("upload_date")),
                "height": _finite_number(raw.get("height"), integral=True),
                "is_short": True if entry_looks_short or intent.kind == "creatorShorts" else raw.get("is_short") if isinstance(raw.get("is_short"), bool) else None,
                "is_live": raw.get("is_live") if isinstance(raw.get("is_live"), bool) else (raw.get("live_status") in {"is_live", "is_upcoming"}) if raw.get("live_status") is not None else None,
            }
        )

    reported_count = _playlist_reported_count(info)
    is_truncated = had_sentinel or (
        reported_count is not None
        and reported_count > len(raw_entries)
    )
    known_sizes = [
        entry["estimated_bytes"]
        for entry in entries
        if isinstance(entry["estimated_bytes"], int)
    ]
    estimated_total_bytes = sum(known_sizes) if known_sizes else None
    title = _redact_text(info.get("title"), maximum=512)
    if title is None:
        title = "YouTube playlist"
    kind = intent.kind
    if (
        kind == "playlist"
        and available_entry_count > 0
        and all_available_entries_are_shorts
    ):
        kind = "shorts"

    analysis = {
        "canonical_url": intent.canonical_url,
        "playlist_id": intent.playlist_id,
        "kind": kind,
        "referenced_video_id": intent.referenced_video_id,
        "title": title,
        "creator": _redact_text(
            info.get("channel") or info.get("uploader"),
            maximum=512,
        ),
        "thumbnail_url": _playlist_thumbnail(info),
        "reported_item_count": reported_count,
        "estimated_total_bytes": estimated_total_bytes,
        "entries": entries,
        "is_truncated": is_truncated,
    }
    if len(
        json.dumps(
            analysis,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    ) > _MAX_OUTPUT_BYTES:
        raise SafeExtractionFailure(
            "metadata_too_large",
            "The extracted playlist exceeds Illucet's output limit.",
        )
    return analysis


def _all_related_exceptions(error: BaseException) -> list[BaseException]:
    related: list[BaseException] = []
    current: BaseException | None = error
    seen: set[int] = set()
    while current is not None and id(current) not in seen and len(related) < 8:
        seen.add(id(current))
        related.append(current)
        nested: BaseException | None = None
        if isinstance(current, DownloadError):
            exc_info = current.exc_info
            if (
                isinstance(exc_info, tuple)
                and len(exc_info) >= 2
                and isinstance(exc_info[1], BaseException)
            ):
                nested = exc_info[1]
        current = nested or current.__cause__ or current.__context__
    return related


def classify_extraction_error(error: BaseException) -> SafeExtractionFailure:
    """Map yt-dlp failures without exposing its message or traceback."""

    related = _all_related_exceptions(error)
    provider_failure = next(
        (
            item
            for item in related
            if isinstance(
                item,
                illucet_ytdlp_provider.IllucetProviderFailure,
            )
        ),
        None,
    )
    if provider_failure is not None:
        reason = getattr(
            provider_failure,
            "reason",
            "provider_failure",
        )
        return SafeExtractionFailure(
            f"javascript_challenge_failure.{reason}",
            "The in-process JavaScript challenge could not be solved.",
            True,
        )
    if any(isinstance(item, GeoRestrictedError) for item in related):
        return SafeExtractionFailure(
            "regional_restriction",
            "This media is unavailable in the current region.",
        )
    if any(isinstance(item, UnsupportedError) for item in related):
        return SafeExtractionFailure(
            "unsupported_site",
            "No supported extractor accepted this URL.",
        )

    classification_text = " ".join(str(item)[:8_192] for item in related)
    lowered = classification_text.lower()
    mappings = (
        (
            ("private video", "this video is private"),
            "private_media",
            "This media is private.",
            False,
        ),
        (
            (
                "sign in to confirm",
                "login required",
                "login-required",
                "members-only",
            ),
            "login_required",
            "This media requires an authenticated account.",
            False,
        ),
        (
            ("age-restricted", "confirm your age", "age restriction"),
            "age_restriction",
            "This media is age restricted.",
            False,
        ),
        (
            (
                "not available in your country",
                "not available in your region",
                "geo restricted",
            ),
            "regional_restriction",
            "This media is unavailable in the current region.",
            False,
        ),
        (
            ("video has been removed", "removed by the uploader"),
            "removed_media",
            "This media has been removed.",
            False,
        ),
        (
            ("premiere will begin", "not yet available", "upcoming"),
            "live_stream_not_yet_available",
            "This live media is not available yet.",
            True,
        ),
        (
            ("live stream", "currently live", "is live"),
            "live_stream_in_progress",
            "This live stream is still in progress.",
            True,
        ),
        (
            ("no video formats", "requested format is not available"),
            "no_compatible_format",
            "No compatible media format is available.",
            True,
        ),
        (
            (
                "javascript challenge",
                "signature solving",
                "nsig extraction",
            ),
            "javascript_challenge_failure",
            "The in-process JavaScript challenge could not be solved.",
            True,
        ),
        (
            ("update to a newer version", "outdated"),
            "extractor_outdated",
            "The bundled extractor may be out of date.",
            True,
        ),
        (
            (
                "timed out",
                "network is unreachable",
                "name or service not known",
                "temporary failure in name resolution",
                "not connected to the internet",
            ),
            "network_failure",
            "The network request failed or timed out.",
            True,
        ),
    )
    for markers, code, message, retryable in mappings:
        if any(marker in lowered for marker in markers):
            return SafeExtractionFailure(code, message, retryable)
    if any(isinstance(item, ExtractorError) for item in related):
        return SafeExtractionFailure(
            "extraction_failed",
            "The media extractor could not analyze this URL.",
            True,
        )
    return SafeExtractionFailure(
        "unknown_internal_error",
        "An internal extraction error occurred.",
        True,
    )


def _options(logger: _SafeLogger) -> dict[str, object]:
    return {
        "age_limit": 0,
        "allow_unplayable_formats": False,
        "allowed_extractors": ["youtube"],
        "cachedir": False,
        "check_formats": False,
        "compat_opts": set(),
        "debug_printtraffic": False,
        "enable_file_urls": False,
        "extract_flat": False,
        "extractor_retries": 1,
        "file_access_retries": 0,
        "fragment_retries": 0,
        "geo_bypass": False,
        "ignoreerrors": False,
        "ignore_no_formats_error": False,
        "js_runtimes": {},
        "logger": logger,
        "noplaylist": True,
        "no_warnings": True,
        "nocheckcertificate": False,
        "proxy": "",
        "prefer_insecure": False,
        "quiet": True,
        "remote_components": set(),
        "retries": 1,
        "simulate": True,
        "skip_download": True,
        "socket_timeout": 15,
        "verbose": False,
        "warn_when_outdated": False,
    }


def _playlist_options(
    logger: _SafeLogger,
    *,
    maximum_entries: int,
) -> dict[str, object]:
    options = _options(logger)
    options.update(
        {
            "allowed_extractors": ["youtube", "youtube:tab", "youtube:playlist"],
            "extract_flat": True,
            "ignoreerrors": True,
            "ignore_no_formats_error": True,
            "noplaylist": False,
            "playlistend": maximum_entries + 1,
        }
    )
    return options


def extract_playlist(
    request: dict[str, Any],
    *,
    ydl_factory: Callable[[dict[str, object]], object] = YoutubeDL,
    emit_event: Callable[..., None] | None = None,
) -> dict[str, object]:
    """Extract a bounded flat playlist inventory without media downloads."""

    if request.get("download", False) is not False:
        raise SafeExtractionFailure(
            "downloads_disabled",
            "This bridge action performs playlist analysis only.",
        )
    maximum_entries = request.get("maximum_entries", 100)
    if (
        isinstance(maximum_entries, bool)
        or not isinstance(maximum_entries, int)
        or not 1 <= maximum_entries <= _MAX_PLAYLIST_ENTRIES
    ):
        raise SafeExtractionFailure(
            "invalid_playlist_limit",
            "The playlist item limit must be between 1 and 500.",
        )
    detailed = request.get("detailed_entries", False)
    if not isinstance(detailed, bool):
        raise SafeExtractionFailure("invalid_request", "Detailed collection analysis must be a boolean.")
    intent = _normalize_youtube_playlist_url(request.get("url"))
    if (
        ytdlp_dependencies.certifi is None
        or ytdlp_dependencies.certifi.where() != certifi.where()
        or not os.path.isfile(certifi.where())
    ):
        raise SafeExtractionFailure(
            "tls_configuration_failed",
            "The bundled TLS certificate store is unavailable.",
        )

    logger = _SafeLogger()
    _checkpoint()
    if emit_event is not None:
        emit_event(
            "progress",
            stage="extracting_playlist",
            completed=0,
            total=1,
        )
    options = _playlist_options(
        logger,
        maximum_entries=maximum_entries,
    )
    if detailed:
        options["extract_flat"] = False
    with illucet_accounts.downloader(request, ydl_factory, options) as ydl:
        info = ydl.extract_info(intent.extraction_url, download=False)
    _checkpoint()
    analysis = _sanitize_playlist(
        info,
        intent=intent,
        maximum_entries=maximum_entries,
    )
    _checkpoint()
    if emit_event is not None:
        emit_event(
            "progress",
            stage="extracting_playlist",
            completed=1,
            total=1,
        )
    return analysis


def extract_metadata(
    request: dict[str, Any],
    *,
    ydl_factory: Callable[[dict[str, object]], object] = YoutubeDL,
    emit_event: Callable[..., None] | None = None,
) -> dict[str, object]:
    """Extract one video's metadata without downloading any media bytes."""

    if request.get("download", False) is not False:
        raise SafeExtractionFailure(
            "downloads_disabled",
            "This bridge action performs metadata extraction only.",
        )
    normalized_url = _normalize_youtube_url(request.get("url"))
    _checkpoint()
    recent = _recent_entry(normalized_url, request)
    if request.get("reuse_recent_extraction") is True and recent is not None:
        result = json.loads(recent[2])["extraction"]
        result["reuse_token"] = recent[1]
        return result
    # Explicit analysis and retry preparation invalidate the older handoff even
    # if the subsequent extraction fails.
    _recent_extractions.pop(normalized_url, None)
    if (
        ytdlp_dependencies.certifi is None
        or ytdlp_dependencies.certifi.where() != certifi.where()
        or not os.path.isfile(certifi.where())
    ):
        raise SafeExtractionFailure(
            "tls_configuration_failed",
            "The bundled TLS certificate store is unavailable.",
        )
    logger = _SafeLogger()
    diagnostics_token = (
        illucet_ytdlp_provider.begin_extraction_diagnostics()
    )
    diagnostics: dict[str, object]
    try:
        _checkpoint()
        if emit_event is not None:
            emit_event(
                "progress",
                stage="extracting_metadata",
                completed=0,
                total=1,
            )
        options = _options(logger)
        with illucet_accounts.downloader(request, ydl_factory, options) as ydl:
            info = ydl.extract_info(normalized_url, download=False)
        _checkpoint()
        metadata = sanitize_metadata(
            info,
            normalized_input_url=normalized_url,
        )
        _checkpoint()
    finally:
        diagnostics = (
            illucet_ytdlp_provider.finish_extraction_diagnostics(
                diagnostics_token
            )
        )

    contract = illucet_ytdlp_provider.contract_details()
    format_inventory_json = json.dumps(
        metadata["formats"],
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    provider_evidence = {
        **contract,
        **diagnostics,
        "external_js_runtimes_enabled": False,
        "remote_components_enabled": False,
        "format_count": len(metadata["formats"]),
        "format_inventory_sha256": hashlib.sha256(
            format_inventory_json
        ).hexdigest(),
        "warning_count": logger.warning_count,
        "error_count": logger.error_count,
    }
    if emit_event is not None:
        emit_event(
            "progress",
            stage="extracting_metadata",
            completed=1,
            total=1,
        )
    result = {
        "metadata": metadata,
        "provider_evidence": provider_evidence,
    }
    _remember_extraction(normalized_url, request, info, result)
    return result


def _resolved_media_url(value: object) -> str:
    raw_url = _bounded_text(value, maximum=16_384, required=True)
    assert raw_url is not None
    try:
        parsed = urlsplit(raw_url)
        port = parsed.port
    except (TypeError, ValueError):
        raise SafeExtractionFailure(
            "invalid_stream_url",
            "The extractor returned an invalid media URL.",
            True,
        ) from None
    host = (parsed.hostname or "").rstrip(".").lower()
    if (
        parsed.scheme.lower() != "https"
        or parsed.username is not None
        or parsed.password is not None
        or port not in {None, 443}
        or not any(host.endswith(suffix) for suffix in _MEDIA_HOST_SUFFIXES)
    ):
        raise SafeExtractionFailure(
            "unsupported_stream_host",
            "The selected stream uses an unsupported delivery host.",
            True,
        )
    return raw_url


def _resolved_headers(value: object) -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    headers: dict[str, str] = {}
    for raw_name, raw_value in value.items():
        if not isinstance(raw_name, str) or not isinstance(raw_value, str):
            continue
        name = raw_name.strip()
        lowered = name.lower()
        if (
            lowered not in _ALLOWED_STREAM_HEADERS
            or (lowered == "sec-fetch-mode" and raw_value != "navigate")
            or len(name) > 64
            or len(raw_value) > 1_024
            or "\r" in raw_value
            or "\n" in raw_value
        ):
            continue
        headers[name] = raw_value
    return headers


def _http_chunk_size_hint(value: object) -> int | None:
    """Project only yt-dlp's bounded, typed HTTP chunk-size hint."""

    if not isinstance(value, dict):
        return None
    hint = value.get("http_chunk_size")
    if (
        isinstance(hint, bool)
        or not isinstance(hint, int)
        or not 1 <= hint <= _MAX_HTTP_CHUNK_SIZE_BYTES
    ):
        return None
    return hint


def _availability_deadline(value: object) -> int | float | None:
    """Preserve yt-dlp's absolute not-before time; never invent a delay."""
    if value is None:
        return None
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or value < 0
        or value > time.time() + _MAX_STREAM_AVAILABILITY_WAIT_SECONDS
        or not math.isfinite(value)
    ):
        raise SafeExtractionFailure(
            "invalid_stream_availability",
            "The selected stream has an invalid availability time.",
        )
    return value


def _resolved_fragment_headers(value: object) -> dict[str, str]:
    """Accept only a complete allowlisted fragment-header dictionary."""

    if value is None:
        return {}
    if not isinstance(value, dict) or len(value) > len(_ALLOWED_STREAM_HEADERS):
        raise SafeExtractionFailure(
            "invalid_fragment_headers",
            "The selected DASH format uses unsupported request headers.",
        )
    headers = _resolved_headers(value)
    if (
        len(headers) != len(value)
        or len({name.lower() for name in headers}) != len(headers)
    ):
        raise SafeExtractionFailure(
            "invalid_fragment_headers",
            "The selected DASH format uses unsupported request headers.",
        )
    return headers


def _resolved_hls_headers(value: object) -> dict[str, str]:
    """Accept only a complete allowlisted HLS request-header dictionary."""

    if value is None:
        return {}
    if not isinstance(value, dict) or len(value) > len(_ALLOWED_STREAM_HEADERS):
        raise SafeExtractionFailure(
            "invalid_hls_headers",
            "The selected HLS format uses unsupported request headers.",
        )
    headers = _resolved_headers(value)
    if (
        len(headers) != len(value)
        or len({name.lower() for name in headers}) != len(headers)
    ):
        raise SafeExtractionFailure(
            "invalid_hls_headers",
            "The selected HLS format uses unsupported request headers.",
        )
    return headers


def _resolved_dash_fragment_url(
    value: object,
    *,
    fragment_base_url: object,
) -> str:
    if not isinstance(value, dict):
        raise SafeExtractionFailure(
            "malformed_fragment_plan",
            "The selected DASH fragment plan is malformed.",
        )
    if any(
        field in value
        for field in (
            "index",
            "frag_index",
            "fragment_index",
            "http_headers",
            "headers",
            "cookie",
            "cookies",
        )
    ):
        raise SafeExtractionFailure(
            "ambiguous_fragment_order",
            "The selected DASH fragment order is ambiguous.",
        )

    raw_url = value.get("url")
    raw_path = value.get("path")
    if raw_url is not None and raw_path is not None:
        raise SafeExtractionFailure(
            "ambiguous_fragment_transport",
            "The selected DASH fragment transport is ambiguous.",
        )
    if raw_url is not None:
        if not isinstance(raw_url, str) or not raw_url:
            raise SafeExtractionFailure(
                "malformed_fragment_plan",
                "The selected DASH fragment plan is malformed.",
            )
        return _resolved_media_url(raw_url)

    if not isinstance(raw_path, str) or not raw_path:
        raise SafeExtractionFailure(
            "malformed_fragment_plan",
            "The selected DASH fragment plan is malformed.",
        )
    path_parts = urlsplit(raw_path)
    if path_parts.scheme or path_parts.netloc or raw_path.startswith("/"):
        raise SafeExtractionFailure(
            "ambiguous_fragment_transport",
            "The selected DASH fragment transport is ambiguous.",
        )
    base_url = _resolved_media_url(fragment_base_url)
    return _resolved_media_url(urljoin(base_url, raw_path))


def _resolved_dash_exact_bytes(value: object) -> int | None:
    """Project only yt-dlp's documented exact integer byte counts."""

    if value is None:
        return None
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < 0
        or value > 9_223_372_036_854_775_807
    ):
        raise SafeExtractionFailure(
            "invalid_fragment_integrity_metadata",
            "The selected DASH format contains invalid exact byte-count metadata.",
        )
    return value


def _resolved_dash_extension(value: object) -> str:
    """Project only container extensions supported by the native probe."""

    extension = _bounded_text(value, maximum=32)
    if extension is None:
        raise SafeExtractionFailure(
            "unsupported_dash_container",
            "The selected DASH format has no trustworthy container extension.",
        )
    normalized = extension.lower()
    if normalized not in {"m4a", "mp4", "webm"}:
        raise SafeExtractionFailure(
            "unsupported_dash_container",
            "The selected DASH format container is unsupported.",
        )
    return normalized


def _resolved_hls_extension(value: object) -> str:
    """Project only exact HLS extensions accepted by native media handling."""

    extension = _bounded_text(value, maximum=32)
    if extension is None:
        raise SafeExtractionFailure(
            "unsupported_hls_container",
            "The selected HLS format has no trustworthy container extension.",
        )
    normalized = extension.lower()
    if normalized not in {"m4a", "mp4", "webm"}:
        raise SafeExtractionFailure(
            "unsupported_hls_container",
            "The selected HLS format container is unsupported.",
        )
    return normalized


def _resolved_dash_fragment(
    position: int,
    value: object,
    *,
    fragment_base_url: object,
) -> dict[str, object]:
    URL = _resolved_dash_fragment_url(
        value,
        fragment_base_url=fragment_base_url,
    )
    if not isinstance(value, dict):
        raise SafeExtractionFailure(
            "malformed_fragment_plan",
            "The selected DASH fragment plan is malformed.",
        )
    return {
        "position": position,
        "url": URL,
        "expected_bytes": _resolved_dash_exact_bytes(
            value.get("filesize")
        ),
    }


def _require_completed_fragment_source(info: dict[str, Any], code: str) -> None:
    # yt-dlp distinguishes processed replays (was_live) from post-live DVR
    # that may still grow. Only the former can use our finite VOD paths.
    is_live = info.get("is_live")
    if (
        (is_live is not None and is_live is not False)
        or info.get("live_status") not in (None, "not_live", "was_live")
    ):
        raise SafeExtractionFailure(
            code,
            "Active, upcoming, and still-processing streams are not supported.",
        )


def resolve_dash_fragment_plan(
    request: dict[str, Any],
    *,
    ydl_factory: Callable[[dict[str, object]], object] = YoutubeDL,
    emit_event: Callable[..., None] | None = None,
) -> dict[str, object]:
    """Resolve one exact bounded non-live DASH format in source order."""

    if request.get("download", False) is not False:
        raise SafeExtractionFailure(
            "downloads_disabled",
            "This bridge action resolves DASH fragments only.",
        )
    normalized_url = _normalize_youtube_url(request.get("url"))
    format_id = request.get("format_id")
    if (
        not isinstance(format_id, str)
        or not format_id
        or len(format_id) > 256
    ):
        raise SafeExtractionFailure(
            "invalid_format_selection",
            "Choose one exact DASH format ID.",
        )

    logger = _SafeLogger()
    if emit_event is not None:
        emit_event(
            "progress",
            stage="resolving_dash_fragments",
            completed=0,
            total=1,
        )
    with illucet_accounts.downloader(request, ydl_factory, _options(logger)) as ydl:
        info = ydl.extract_info(normalized_url, download=False)
    _checkpoint()
    if not isinstance(info, dict):
        raise SafeExtractionFailure(
            "invalid_metadata",
            "The extractor did not return a media record.",
        )

    video_id = _bounded_text(info.get("id"), maximum=256, required=True)
    if video_id is None or not _VIDEO_ID.fullmatch(video_id):
        raise SafeExtractionFailure(
            "verification_mismatch",
            "The stream identity could not be verified.",
        )
    input_video_id = normalized_url.rsplit("/", 1)[-1]
    if "watch?v=" in normalized_url:
        input_video_id = normalized_url.rsplit("=", 1)[-1]
    if input_video_id != video_id:
        raise SafeExtractionFailure(
            "verification_mismatch",
            "The resolved stream identity does not match the requested URL.",
        )
    _require_completed_fragment_source(info, "unsupported_live_fragment_plan")

    raw_formats = info.get("formats")
    if not isinstance(raw_formats, (list, tuple)):
        raise SafeExtractionFailure(
            "no_compatible_format",
            "No usable media formats were returned.",
            True,
        )
    if len(raw_formats) > _MAX_FORMATS:
        raise SafeExtractionFailure(
            "metadata_too_large",
            "The format list exceeds Illucet's safety limit.",
        )
    matches = [
        raw_format
        for raw_format in raw_formats
        if isinstance(raw_format, dict)
        and raw_format.get("format_id") == format_id
    ]
    if len(matches) != 1:
        raise SafeExtractionFailure(
            "ambiguous_format_selection"
            if matches
            else "format_expired_or_unavailable",
            "The exact selected DASH format is unavailable or ambiguous.",
            not matches,
        )
    raw_format = matches[0]
    if raw_format.get("has_drm") not in (None, False):
        raise SafeExtractionFailure(
            "drm_format_unsupported",
            "DRM-protected DASH formats are not supported.",
        )
    if raw_format.get("is_from_start") not in (None, False):
        raise SafeExtractionFailure(
            "unsupported_live_fragment_plan",
            "Live-from-start DASH fragment plans are not supported.",
        )

    protocol = _bounded_text(raw_format.get("protocol"), maximum=64)
    if protocol != "http_dash_segments" or _source_type(protocol) != "dash":
        raise SafeExtractionFailure(
            "unsupported_stream_protocol",
            "The selected format is not an exact supported DASH fragment plan.",
        )
    if info.get("extra_param_to_segment_url") not in (None, "") or raw_format.get(
        "extra_param_to_segment_url"
    ) not in (None, ""):
        raise SafeExtractionFailure(
            "unsupported_fragment_transport",
            "The selected DASH format requires unsupported fragment transport parameters.",
        )

    if "account_cookies" in request:
        illucet_accounts.validate_media_transport(raw_format)
    raw_fragments = raw_format.get("fragments")
    if isinstance(raw_fragments, (str, bytes, bytearray)) or not isinstance(
        raw_fragments,
        Sequence,
    ):
        raise SafeExtractionFailure(
            "fragment_order_unavailable",
            "The selected DASH format does not expose a trustworthy fragment order.",
        )
    bounded_fragments = list(
        itertools.islice(raw_fragments, _MAX_DASH_FRAGMENTS + 1)
    )
    if not bounded_fragments:
        raise SafeExtractionFailure(
            "empty_fragment_plan",
            "The selected DASH format contains no fragments.",
        )
    if len(bounded_fragments) > _MAX_DASH_FRAGMENTS:
        raise SafeExtractionFailure(
            "fragment_plan_too_large",
            "The selected DASH fragment plan exceeds Illucet's safety limit.",
        )

    fragments = [
        _resolved_dash_fragment(
            position,
            fragment,
            fragment_base_url=raw_format.get("fragment_base_url"),
        )
        for position, fragment in enumerate(bounded_fragments)
    ]
    video_codec = _codec(raw_format.get("vcodec"))
    audio_codec = _codec(raw_format.get("acodec"))
    if video_codec is None and audio_codec is None:
        raise SafeExtractionFailure(
            "no_compatible_format",
            "The selected DASH format contains no media stream.",
        )
    plan: dict[str, object] = {
        "video_id": video_id,
        "format_id": format_id,
        "protocol": protocol,
        "source_type": "dash",
        "extension": _resolved_dash_extension(raw_format.get("ext")),
        "has_video": video_codec is not None,
        "has_audio": audio_codec is not None,
        "expected_bytes": _resolved_dash_exact_bytes(
            raw_format.get("filesize")
        ),
        "http_headers": _resolved_fragment_headers(
            raw_format.get("http_headers")
        ),
        "fragment_count": len(fragments),
        "fragments": fragments,
    }
    if (deadline := _availability_deadline(raw_format.get("available_at"))) is not None:
        plan["available_at"] = deadline
    if len(
        json.dumps(
            plan,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    ) > _MAX_OUTPUT_BYTES:
        raise SafeExtractionFailure(
            "fragment_plan_too_large",
            "The selected DASH fragment plan exceeds Illucet's safety limit.",
        )
    if emit_event is not None:
        emit_event(
            "progress",
            stage="resolving_dash_fragments",
            completed=1,
            total=1,
        )
    return plan


def resolve_hls_playlist_plan(
    request: dict[str, Any],
    *,
    ydl_factory: Callable[[dict[str, object]], object] = YoutubeDL,
    emit_event: Callable[..., None] | None = None,
) -> dict[str, object]:
    """Resolve exact HLS master/media playlist identity without fetching it."""

    if request.get("download", False) is not False:
        raise SafeExtractionFailure(
            "downloads_disabled",
            "This bridge action resolves HLS playlist identity only.",
        )
    normalized_url = _normalize_youtube_url(request.get("url"))
    format_id = request.get("format_id")
    if (
        not isinstance(format_id, str)
        or not format_id
        or len(format_id) > 256
    ):
        raise SafeExtractionFailure(
            "invalid_format_selection",
            "Choose one exact HLS format ID.",
        )

    logger = _SafeLogger()
    if emit_event is not None:
        emit_event(
            "progress",
            stage="resolving_hls_playlist",
            completed=0,
            total=1,
        )
    with illucet_accounts.downloader(request, ydl_factory, _options(logger)) as ydl:
        info = ydl.extract_info(normalized_url, download=False)
    _checkpoint()
    if not isinstance(info, dict):
        raise SafeExtractionFailure(
            "invalid_metadata",
            "The extractor did not return a media record.",
        )

    video_id = _bounded_text(info.get("id"), maximum=256, required=True)
    if video_id is None or not _VIDEO_ID.fullmatch(video_id):
        raise SafeExtractionFailure(
            "verification_mismatch",
            "The stream identity could not be verified.",
        )
    input_video_id = normalized_url.rsplit("/", 1)[-1]
    if "watch?v=" in normalized_url:
        input_video_id = normalized_url.rsplit("=", 1)[-1]
    if input_video_id != video_id:
        raise SafeExtractionFailure(
            "verification_mismatch",
            "The resolved stream identity does not match the requested URL.",
        )
    _require_completed_fragment_source(info, "unsupported_live_hls_playlist")

    raw_formats = info.get("formats")
    if not isinstance(raw_formats, (list, tuple)):
        raise SafeExtractionFailure(
            "no_compatible_format",
            "No usable media formats were returned.",
            True,
        )
    if len(raw_formats) > _MAX_FORMATS:
        raise SafeExtractionFailure(
            "metadata_too_large",
            "The format list exceeds Illucet's safety limit.",
        )
    matches = [
        raw_format
        for raw_format in raw_formats
        if isinstance(raw_format, dict)
        and raw_format.get("format_id") == format_id
    ]
    if len(matches) != 1:
        raise SafeExtractionFailure(
            "ambiguous_format_selection"
            if matches
            else "format_expired_or_unavailable",
            "The exact selected HLS format is unavailable or ambiguous.",
            not matches,
        )
    raw_format = matches[0]
    if raw_format.get("has_drm") not in (None, False):
        raise SafeExtractionFailure(
            "drm_format_unsupported",
            "DRM-protected HLS formats are not supported.",
        )
    if raw_format.get("is_from_start") not in (None, False):
        raise SafeExtractionFailure(
            "unsupported_live_hls_playlist",
            "Live-from-start HLS playlists are not supported.",
        )

    protocol = _bounded_text(raw_format.get("protocol"), maximum=64)
    if protocol not in {"m3u8", "m3u8_native"} or _source_type(protocol) != "hls":
        raise SafeExtractionFailure(
            "unsupported_stream_protocol",
            "The selected format is not an exact supported HLS playlist.",
        )
    if (
        raw_format.get("request_data") not in (None, b"", "")
        or raw_format.get("cookies") not in (None, "")
        or raw_format.get("impersonate") is not None
        or raw_format.get("hls_aes") is not None
        or raw_format.get("extra_param_to_segment_url") not in (None, "")
        or raw_format.get("extra_param_to_key_url") not in (None, "")
        or raw_format.get("hls_media_playlist_data") is not None
    ):
        raise SafeExtractionFailure(
            "unsupported_hls_transport",
            "The selected HLS format requires unsupported transport parameters.",
        )

    if "account_cookies" in request:
        illucet_accounts.validate_media_transport(raw_format)
    media_playlist_url = _resolved_media_url(raw_format.get("url"))
    raw_manifest_url = raw_format.get("manifest_url")
    manifest_url = _resolved_media_url(
        media_playlist_url if raw_manifest_url is None else raw_manifest_url
    )
    video_codec = _codec(raw_format.get("vcodec"))
    audio_codec = _codec(raw_format.get("acodec"))
    if video_codec is None and audio_codec is None:
        raise SafeExtractionFailure(
            "no_compatible_format",
            "The selected HLS format contains no media stream.",
        )
    plan: dict[str, object] = {
        "video_id": video_id,
        "format_id": format_id,
        "protocol": protocol,
        "source_type": "hls",
        "extension": _resolved_hls_extension(raw_format.get("ext")),
        "has_video": video_codec is not None,
        "has_audio": audio_codec is not None,
        "http_headers": _resolved_hls_headers(
            raw_format.get("http_headers")
        ),
        "manifest_url": manifest_url,
        "media_playlist_url": media_playlist_url,
    }
    if (deadline := _availability_deadline(raw_format.get("available_at"))) is not None:
        plan["available_at"] = deadline
    if len(
        json.dumps(
            plan,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    ) > _MAX_HLS_PLAN_OUTPUT_BYTES:
        raise SafeExtractionFailure(
            "hls_plan_too_large",
            "The selected HLS playlist identity exceeds Illucet's safety limit.",
        )
    if emit_event is not None:
        emit_event(
            "progress",
            stage="resolving_hls_playlist",
            completed=1,
            total=1,
        )
    return plan


def resolve_streams(
    request: dict[str, Any],
    *,
    ydl_factory: Callable[[dict[str, object]], object] = YoutubeDL,
    emit_event: Callable[..., None] | None = None,
) -> dict[str, object]:
    """Resolve exact format IDs without downloading or persisting secrets."""

    normalized_url = _normalize_youtube_url(request.get("url"))
    format_ids = request.get("format_ids")
    if (
        not isinstance(format_ids, list)
        or not 1 <= len(format_ids) <= 3
        or any(
            not isinstance(format_id, str)
            or not format_id
            or len(format_id) > 256
            for format_id in format_ids
        )
        or len(set(format_ids)) != len(format_ids)
    ):
        raise SafeExtractionFailure(
            "invalid_format_selection",
            "Choose one or more available format IDs.",
        )
    logger = _SafeLogger()
    if emit_event is not None:
        emit_event(
            "progress",
            stage="resolving_streams",
            completed=0,
            total=1,
        )
    _checkpoint()
    recent = _recent_entry(normalized_url, request)
    # Consume once. All recovery calls omit the token and must extract fresh.
    _recent_extractions.pop(normalized_url, None)
    info = None
    if recent is not None and request.get("reuse_token") == recent[1]:
        candidate = json.loads(recent[2])["info"]
        available = {item["format_id"] for item in candidate["formats"]}
        if set(format_ids).issubset(available):
            info = candidate
    if info is None:
        options = _options(logger)
        with illucet_accounts.downloader(request, ydl_factory, options) as ydl:
            info = ydl.extract_info(normalized_url, download=False)
    _checkpoint()
    if not isinstance(info, dict):
        raise SafeExtractionFailure(
            "invalid_metadata",
            "The extractor did not return a media record.",
        )
    video_id = _bounded_text(
        info.get("id"),
        maximum=256,
        required=True,
    )
    if video_id is None or not _VIDEO_ID.fullmatch(video_id):
        raise SafeExtractionFailure(
            "verification_mismatch",
            "The stream identity could not be verified.",
        )
    raw_formats = info.get("formats")
    if not isinstance(raw_formats, (list, tuple)):
        raise SafeExtractionFailure(
            "no_compatible_format",
            "No usable media formats were returned.",
            True,
        )
    by_id = {
        raw_format.get("format_id"): raw_format
        for raw_format in raw_formats
        if isinstance(raw_format, dict)
        and isinstance(raw_format.get("format_id"), str)
    }
    streams: list[dict[str, object]] = []
    for format_id in format_ids:
        raw_format = by_id.get(format_id)
        if not isinstance(raw_format, dict) or raw_format.get("has_drm") is True:
            raise SafeExtractionFailure(
                "format_expired_or_unavailable",
                "A selected format is no longer available. Analyze again.",
                True,
            )
        protocol = _bounded_text(raw_format.get("protocol"), maximum=64)
        source_type = _source_type(protocol)
        if source_type != "direct_http":
            raise SafeExtractionFailure(
                "unsupported_stream_protocol",
                "The selected stream requires a manifest downloader that is not available in this build.",
            )
        video_codec = _codec(raw_format.get("vcodec"))
        audio_codec = _codec(raw_format.get("acodec"))
        exact_size = _finite_number(
            raw_format.get("filesize"),
            integral=True,
        )
        approximate_size = _finite_number(
            raw_format.get("filesize_approx"),
            integral=True,
        )
        if "account_cookies" in request:
            illucet_accounts.validate_media_transport(raw_format)
        stream: dict[str, object] = {
            "format_id": format_id,
            "url": _resolved_media_url(raw_format.get("url")),
            "http_headers": _resolved_headers(
                raw_format.get("http_headers")
            ),
            "extension": _bounded_text(
                raw_format.get("ext"),
                maximum=32,
            ),
            "protocol": protocol or "https",
            "source_type": source_type,
            "has_video": video_codec is not None,
            "has_audio": audio_codec is not None,
            "expected_bytes": exact_size or approximate_size,
        }
        chunk_size = _http_chunk_size_hint(
            raw_format.get("downloader_options")
        )
        if chunk_size is not None:
            stream["http_chunk_size"] = chunk_size
        if (deadline := _availability_deadline(raw_format.get("available_at"))) is not None:
            stream["available_at"] = deadline
        streams.append(stream)
    if emit_event is not None:
        emit_event(
            "progress",
            stage="resolving_streams",
            completed=1,
            total=1,
        )
    return {
        "video_id": video_id,
        "streams": streams,
    }
