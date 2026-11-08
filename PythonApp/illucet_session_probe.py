"""Read-only authentication feasibility probe; no cookie files or global sessions."""

from __future__ import annotations

from http.cookiejar import Cookie
import re
import time

from yt_dlp import YoutubeDL
import illucet_ytdlp_extractor as extractor


def _invalid():
    return extractor.SafeExtractionFailure(
        "invalid_session", "The temporary YouTube session is invalid or expired.")


def _cookies(records):
    if not isinstance(records, list) or not 1 <= len(records) <= 128:
        raise _invalid()
    result = []
    seen = set()
    total = 0
    for record in records:
        if not isinstance(record, dict) or set(record) != {
            "domain", "path", "name", "value", "secure", "expires"
        }:
            raise _invalid()
        domain, path, name, value = (record[k] for k in ("domain", "path", "name", "value"))
        if not all(isinstance(item, str) for item in (domain, path, name, value)):
            raise _invalid()
        # Only the app-owned YouTube session, never Google account cookies or
        # media/CDN cookies. Preserve host-only versus domain-cookie semantics.
        if domain not in ("youtube.com", ".youtube.com", "www.youtube.com", "m.youtube.com"):
            raise _invalid()
        if path != "/" or not re.fullmatch(r"[A-Za-z0-9_\-]{1,128}", name):
            raise _invalid()
        if not value or len(value) > 16384 or any(ord(c) < 33 or ord(c) > 126 or c == ";" for c in value):
            raise _invalid()
        if type(record["secure"]) is not bool:
            raise _invalid()
        expires = record["expires"]
        if expires is not None and (type(expires) is not int or not time.time() < expires <= 253402300799):
            raise _invalid()
        identity = (domain, path, name)
        total += len(value)
        if identity in seen or total > 131072:
            raise _invalid()
        seen.add(identity)
        result.append(Cookie(
            version=0, name=name, value=value, port=None, port_specified=False,
            domain=domain, domain_specified=domain.startswith("."),
            domain_initial_dot=domain.startswith("."), path=path, path_specified=True,
            secure=record["secure"], expires=expires, discard=expires is None,
            comment=None, comment_url=None, rest={}, rfc2109=False))
    return result


def probe(request, *, ydl_factory=YoutubeDL):
    """Only report session recognition and exact-video metadata success."""
    if request.get("download") is not False:
        raise _invalid()
    url = extractor._normalize_youtube_url(request.get("url"))
    cookies = _cookies(request.get("cookies"))
    options = extractor._options(extractor._SafeLogger())
    with ydl_factory(options) as ydl:
        try:
            for cookie in cookies:
                ydl.cookiejar.set_cookie(cookie)
            youtube = ydl.get_info_extractor("Youtube")
            if not youtube.is_authenticated:
                raise extractor.SafeExtractionFailure(
                    "login_required", "yt-dlp did not recognize a complete YouTube login session.")
            extractor._checkpoint()
            info = ydl.extract_info(url, download=False)
            extractor._checkpoint()
            if not youtube.is_authenticated:
                raise extractor.SafeExtractionFailure(
                    "login_required", "The temporary login cookies are no longer recognized.")
            metadata = extractor.sanitize_metadata(info, normalized_input_url=url)
            if not metadata["formats"]:
                raise extractor.SafeExtractionFailure(
                    "no_formats", "No usable media formats were returned.")
            # Nothing from raw metadata, cookies, headers or warnings crosses back.
            return {"sessionRecognized": True, "metadataExtracted": True,
                    "formatCount": len(metadata["formats"])}
        finally:
            ydl.cookiejar.clear()
            cookies.clear()
