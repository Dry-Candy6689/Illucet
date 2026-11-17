"""Bounded post extraction and exact asset transfer; no user configs or disk caches.

Transport dictionaries live only in this request. Stable identity comes from
extractor metadata, never a filename or a CDN URL. Existing YouTube contracts are
kept in illucet_ytdlp_extractor.
"""
from __future__ import annotations

import contextlib
import hashlib
import http.cookiejar
import ipaddress
import json
import logging
import os
import re
import sys
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit, urljoin

import _illucet_native
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadCancelled
import illucet_ytdlp_extractor as core

sys.path.insert(0, str(Path(__file__).parent / "_image_packages"))
DOMAINS = {
    "youtube": ("youtube.com", "youtu.be", "youtube-nocookie.com"),
    "tiktok": ("tiktok.com",), "instagram": ("instagram.com",),
    "x": ("x.com", "twitter.com", "t.co"), "reddit": ("reddit.com", "redd.it"),
    "facebook": ("facebook.com", "fb.watch", "fb.com"), "bluesky": ("bsky.app",),
    "vimeo": ("vimeo.com",), "dailymotion": ("dailymotion.com", "dai.ly"),
    "twitch": ("twitch.tv",), "soundcloud": ("soundcloud.com", "snd.sc"),
    "pinterest": ("pinterest.com", "pin.it"),
}
EXTRACTORS = {
    "tiktok": ("TikTok", "vm.tiktok"), "instagram": ("Instagram",), "x": ("twitter", "twitter:shortener", "twitter:amplify"),
    "reddit": ("Reddit",), "facebook": ("facebook", "facebook:reel", "FacebookRedirectURL"),
    "bluesky": ("Bluesky",), "vimeo": ("vimeo",), "dailymotion": ("dailymotion",),
    "twitch": ("twitch:clips", "twitch:vod"), "soundcloud": ("soundcloud", "SoundcloudEmbed"),
    "pinterest": ("Pinterest",), "youtube": ("youtube",),
}
IMAGE_SITES = {"instagram", "x", "reddit", "bluesky", "tiktok", "pinterest", "facebook"}


def resolve_share_url(site, url):
    """Resolve official short links without forwarding account credentials."""
    parsed = urlsplit(url)
    short = parsed.hostname in {"pin.it", "t.co", "vm.tiktok.com", "vt.tiktok.com", "fb.watch", "snd.sc", "dai.ly"}
    short = short or (site == "tiktok" and parsed.path.startswith("/t/"))
    short = short or (site in {"facebook", "instagram"} and parsed.path.startswith("/share/"))
    if not short: return url
    import requests
    with requests.Session() as session:
        session.headers["User-Agent"] = "Mozilla/5.0"
        for _ in range(6):
            check_cancelled()
            with session.get(url, timeout=15, stream=True, allow_redirects=False) as response:
                if response.status_code in {301,302,303,307,308}:
                    destination = urljoin(url, response.headers.get("Location", ""))
                    # Validate before the next request, not after a redirect has
                    # already sent a request to a different/local host.
                    returned_site, canonical = webpage(destination)
                    if returned_site != site: fail("identity_mismatch", "This share link points to another website. Import that link directly.")
                    if urlsplit(canonical).path.startswith(("/login", "/accounts/login", "/checkpoint")):
                        fail("login_required", "Open this shared post and import its full link.")
                    # Shortener handoffs can require query parameters. They live
                    # only in this request; only canonical URLs leave the resolver.
                    url = destination
                    continue
                if response.status_code in {403,429}:
                    fail("service_challenge", "The website refused this share link. Try the full post link.")
                if response.status_code >= 400: fail("post_unavailable", "This shared post is unavailable.")
                return webpage(url)[1]
    fail("invalid_url", "This share link redirected too many times. Import the full post link.")


def fail(code, message):
    raise core.SafeExtractionFailure(code, message)


def check_cancelled():
    if _illucet_native.is_cancelled():
        raise DownloadCancelled("cancelled")


def record_failure(error, stage, engine=None):
    frames = []
    trace = error.__traceback__
    while trace is not None:
        name = trace.tb_frame.f_code.co_name
        frames.append({"function":name if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]{0,80}",name) else "operation", "line":trace.tb_lineno})
        trace = trace.tb_next
    payload = {"stage":stage,"exception_type":type(error).__name__,"frames":frames[-6:]}
    related = core._all_related_exceptions(error)
    payload["causes"] = [type(item).__name__ for item in related]
    payload["http_statuses"] = [status for item in related
        if isinstance(status := getattr(item, "status", getattr(item, "code", None)), int)
        and 100 <= status <= 599]
    message = " ".join(str(item)[:8192] for item in related).lower()
    payload["reason"] = next((code for marker, code in [
        ("no suitable extractor", "no_extractor"), ("http error 403", "http_403"),
        ("http error 429", "http_429"), ("timed out", "timeout"),
        ("no video formats", "no_formats")] if marker in message), "other")
    if engine is not None: payload["extractors"] = list(getattr(engine, "_ies", {}))[:32]
    _illucet_native.emit_json(json.dumps({"kind":"asset_failure","payload":payload},separators=(",",":")))


def webpage(value):
    if not isinstance(value, str) or len(value.encode()) > 4096:
        fail("invalid_url", "Enter a supported media webpage URL.")
    c = urlsplit(value)
    if c.scheme not in ("http", "https") or c.username or c.password or c.port not in (None,80,443):
        fail("invalid_url", "Enter a public HTTP or HTTPS media webpage URL.")
    host = (c.hostname or "").lower()
    site = next((s for s, domains in DOMAINS.items() if any(host == d or host.endswith("."+d) for d in domains)), None)
    if not site:
        fail("unsupported_site", "This website is not supported in Illucet.")
    fields = {"youtube":{"v","list"}, "facebook":{"v","story_fbid","id","fbid","video_id"}, "dailymotion":{"video"}}.get(site,set())
    query = urlencode([(k,v) for k,v in parse_qsl(c.query) if k in fields and re.fullmatch(r"[A-Za-z0-9_-]{1,128}",v)])
    if site == "soundcloud" and len([part for part in c.path.split("/") if part]) > 2:
        fail("private_link_unsupported", "Import a public SoundCloud track link.")
    return site, urlunsplit(("https", host, c.path or "/", query, ""))


def transport_url(value):
    if not isinstance(value, str) or len(value.encode()) > 16384:
        fail("invalid_transport", "The selected asset has an invalid transport URL.")
    c = urlsplit(value)
    if c.scheme not in ("http", "https") or c.username or c.password or not c.hostname:
        fail("invalid_transport", "The selected asset has an invalid transport URL.")
    try:
        address = ipaddress.ip_address(c.hostname)
    except ValueError:
        if c.hostname.lower() == "localhost" or c.hostname.lower().endswith((".localhost", ".local")):
            fail("invalid_transport", "Local network media is unsupported.")
    else:
        if not address.is_global:
            fail("invalid_transport", "Local network media is unsupported.")
    return value


def cookie_jar(request, site):
    jar = http.cookiejar.CookieJar()
    cookies = request.get("site_cookies", [])
    if not isinstance(cookies, list) or len(cookies) > 128:
        fail("invalid_session", "The account session is invalid.")
    for c in cookies:
        domain = str(c.get("domain", "")).lstrip(".").lower()
        if not any(domain == d or domain.endswith("."+d) for d in DOMAINS[site]):
            fail("wrong_account_site", "This account belongs to another website.")
        jar.set_cookie(http.cookiejar.Cookie(0, c["name"], c["value"], None, False,
            c["domain"], True, c["domain"].startswith("."), c.get("path", "/"), True,
            c.get("secure", True), c.get("expires"), c.get("expires") is None, None, None, {}, False))
    return jar


def options(request, site):
    result = core._options(core._SafeLogger())
    result.update(allowed_extractors=[re.escape(name) for name in EXTRACTORS[site]], age_limit=0,
                  noplaylist=True, extract_flat=False, max_downloads=500)
    client = request.get("youtube_client", "default")
    if site == "youtube" and client in {"default", "web_safari", "web", "mweb", "ios", "tv"}:
        result["extractor_args"] = {"youtube": {"player_client": [client]}}
    return result


def mp4_codec_facts(data):
    """Read bounded ISO-BMFF metadata, never infer streams from a URL/extension."""
    import struct
    facts = {}
    codecs = {b"avc1":"h264", b"avc3":"h264", b"hvc1":"hevc", b"hev1":"hevc",
              b"av01":"av1", b"vp09":"vp9", b"mp4a":"aac", b"Opus":"opus", b"fLaC":"flac"}
    def boxes(value):
        position = 0
        while position + 8 <= len(value):
            size, kind = struct.unpack_from(">I4s", value, position); header = 8
            if size == 1:
                if position + 16 > len(value): return
                size = struct.unpack_from(">Q", value, position + 8)[0]; header = 16
            if size == 0: size = len(value) - position
            if size < header or size > len(value) - position: return
            yield kind, value[position + header:position + size]
            position += size
    def find(value, path):
        if not path: return [value]
        return [found for kind, child in boxes(value) if kind == path[0] for found in find(child, path[1:])]
    for moov in find(data, [b"moov"]):
        for track in find(moov, [b"trak"]):
            handlers = find(track, [b"mdia", b"hdlr"])
            descriptions = find(track, [b"mdia", b"minf", b"stbl", b"stsd"])
            if len(handlers) != 1 or len(descriptions) != 1 or len(handlers[0]) < 12 or len(descriptions[0]) < 8: continue
            role = {b"vide":"vcodec", b"soun":"acodec"}.get(handlers[0][8:12])
            entries = list(boxes(descriptions[0][8:]))
            if role and len(entries) == 1 and entries[0][0] in codecs:
                facts[role] = codecs[entries[0][0]]
    return facts


def inspect_missing_codecs(ydl, raw):
    """At most four range requests and 4 MiB for an exact direct source's moov.

    The normal transfer still belongs to Swift. This is bounded extraction of
    container metadata for sites whose upstream formats omit codec facts.
    """
    import struct
    from yt_dlp.networking import Request
    if raw.get("protocol") not in {"http", "https"}: return raw
    if raw.get("vcodec") is not None and raw.get("acodec") is not None: return raw
    url = transport_url(raw.get("url"))
    remaining = 4 * 1024 * 1024
    validator = None
    def read_at(offset, length):
        nonlocal remaining, validator
        check_cancelled()
        headers = core._resolved_headers(raw.get("http_headers"))
        headers["Range"] = f"bytes={offset}-{offset + length - 1}"
        if offset and validator: headers["If-Range"] = validator
        with ydl.urlopen(Request(url, headers=headers)) as response:
            if offset and response.status != 206: return b""
            if response.status == 206:
                match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
                if not match or int(match[1]) != offset: return b""
            current = response.headers.get("ETag")
            if validator and current != validator: return b""
            if not offset: validator = current if current and not current.startswith("W/") else None
            data = response.read(min(length, remaining) + 1)
            remaining -= len(data)
            return data if remaining >= 0 and len(data) <= length else b""
    offset = 0
    for _ in range(4):
        header = read_at(offset, 64 * 1024 if offset == 0 else 16)
        if len(header) < 8: break
        while len(header) >= 8:
            size, kind = struct.unpack_from(">I4s", header); count = 8
            if size == 1:
                if len(header) < 16: return raw
                size = struct.unpack_from(">Q", header, 8)[0]; count = 16
            if size < count or size > 10 ** 12: return raw
            if kind == b"moov":
                body = header[:size] if size <= len(header) else read_at(offset, size) if size <= remaining and validator else b""
                observed = mp4_codec_facts(body)
                if observed: return dict(raw, vcodec=observed.get("vcodec", "none"), acodec=observed.get("acodec", "none"))
                return raw
            offset += size
            if size >= len(header): break
            header = header[size:]
        if not validator: break
    return raw


def av_assets(request, site, url):
    opts = options(request, site)
    with YoutubeDL(opts) as ydl:
        for cookie in cookie_jar(request, site): ydl.cookiejar.set_cookie(cookie)
        try:
            check_cancelled()
            if site == "reddit" and request.get("reddit_page") is not None:
                import illucet_reddit
                info = illucet_reddit.video_info(request, ydl, fail, check_cancelled)
            else:
                info = ydl.extract_info(url, download=False)
            if not isinstance(info, dict): fail("no_media", "No media was found at this link.")
            entries = info.get("entries")
            if entries is not None:
                entries = list(__import__("itertools").islice(entries, 501))
                if len(entries) > 500: fail("too_many_assets", "Select a post with at most 500 media items.")
            else: entries = [info]
            result = []
            parent_id = str(info.get("id") or "")
            for entry in entries:
                check_cancelled()
                if not isinstance(entry, dict) or entry.get("_type") in {"url", "url_transparent"}: continue
                if entry.get("is_live") or entry.get("live_status") in {"is_live", "is_upcoming"}: continue
                asset_id = str(entry.get("id") or "")
                if not asset_id or len(asset_id.encode()) > 256: continue
                formats = entry.get("formats") or [dict(entry, format_id=entry.get("format_id") or "original")]
                verified_formats = []
                probes = 0
                for raw in reversed(formats):
                    if raw.get("has_drm"): continue
                    if probes < 4 and raw.get("protocol") in {"http", "https"} and (raw.get("vcodec") is None or raw.get("acodec") is None):
                        probes += 1
                        try: raw = inspect_missing_codecs(ydl, raw)
                        except DownloadCancelled: raise
                        except Exception: pass  # Missing facts remain unselectable.
                    verified_formats.append(raw)
                formats = list(reversed(verified_formats))
                clean_formats = core._sanitize_formats(formats)
                if not clean_formats: continue
                kind = "video" if any(f["has_video"] for f in clean_formats) else "audio"
                identity = {"site": site, "postID": parent_id or asset_id, "assetID": asset_id, "kind": kind}
                # Only the initial approved site is allowed to supply this record.
                canonical = entry.get("webpage_url") or info.get("webpage_url") or url
                try: returned_site, canonical = webpage(canonical)
                except core.SafeExtractionFailure: canonical = url; returned_site = site
                if returned_site != site: fail("identity_mismatch", "This link resolved to another website. Import its media link directly.")
                metadata = media_metadata(identity, canonical, entry, clean_formats)
                result.append((metadata, entry, formats))
            return result
        except Exception as error:
            record_failure(error, "extract_av_engine", ydl)
            raise
        finally:
            ydl.cookiejar.clear()


def media_metadata(identity, url, info, formats):
    return {"source_identity": identity, "canonical_url": url, "video_id": identity["assetID"],
            "title": core._redact_text(info.get("title") or info.get("description") or "Media post", maximum=512) or "Media post",
            "channel": None, "uploader": core._redact_text(info.get("uploader") or info.get("author"), maximum=512),
            "duration_seconds": core._finite_number(info.get("duration")), "upload_date": None,
            "description": core._redact_text(info.get("description"), maximum=100000), "is_live": False,
            "live_status": None, "thumbnails": [], "chapters": [], "subtitles": [], "formats": formats}


def original_images(request, site, url):
    import illucet_images
    with YoutubeDL(options(request, site)) as ydl:
        jar = cookie_jar(request, site)
        for cookie in jar: ydl.cookiejar.set_cookie(cookie)
        try:
            records = illucet_images.extract(request, site, url, ydl, jar, fail, check_cancelled)
            if len(records) > 500: fail("too_many_assets", "This post exceeds the 500-item limit.")
            result = []
            for record in records:
                check_cancelled()
                post_id, asset_id = record["post"], record["asset"]
                if not all(isinstance(v, str) and 0 < len(v.encode()) <= 256 for v in (post_id, asset_id)):
                    fail("invalid_identity", "The image has no stable post identity.")
                original = transport_url(record["url"])
                identity = {"site":site, "postID":post_id, "assetID":asset_id, "kind":"image"}
                metadata = media_metadata(identity, url, {"title":record.get("title") or f"{site.title()} image"}, [])
                facts = {k:record.get(k) for k in ("post", "asset", "width", "height")}
                # Ordinal identities cannot prove an album was not reordered.
                # Keep a one-way change fence, never the transport itself.
                if asset_id.startswith("item-") or asset_id in {"pin-image", "post-image"}:
                    facts["transport_change_fence"] = hashlib.sha256(original.encode()).hexdigest()
                metadata["asset_fingerprint"] = hashlib.sha256(json.dumps(facts, sort_keys=True).encode()).hexdigest()
                content_proof = site == "tiktok" and asset_id.startswith("item-")
                if content_proof:
                    # Private bridge field consumed and removed by native Swift.
                    # TikTok supplies ordinal photo records without stable media
                    # IDs. Native content hashes survive signed-URL renewal.
                    metadata["_image_content_source"] = original
                suffix = Path(urlsplit(original).path).suffix.lstrip(".").lower()
                ext = suffix if suffix in {"jpg", "jpeg", "png", "webp", "gif", "heic", "avif"} else "image"
                result.append((metadata, {"url":original, "ext":ext, "needsContentFingerprint":content_proof,
                    "http_headers":{"User-Agent":"Mozilla/5.0"}}, []))
            return result
        finally:
            ydl.cookiejar.clear()
            jar.clear()


def inventory(request):
    site, url = webpage(request.get("url"))
    url = resolve_share_url(site, url)
    if site == "reddit" and request.get("reddit_page") is None:
        import illucet_reddit
        illucet_reddit.validate_webpage(url, fail)
        fail("reddit_browser_required", "Reddit requires its browser page for this post.")
    preferred = request.get("identity", {}).get("kind")
    av_error = None
    av = []
    if preferred != "image":
        try: av = av_assets(request, site, url)
        except DownloadCancelled: raise
        except core.SafeExtractionFailure as error: av_error = error
        except Exception as error:
            record_failure(error, "extract_av")
            av_error = core.classify_extraction_error(error)
    images = []
    if site in IMAGE_SITES and preferred not in {"video", "audio"}:
        try: images = original_images(request, site, url)
        except DownloadCancelled: raise
        except Exception as error:
            record_failure(error, "extract_images")
            # Initial discovery must not silently omit photos from a mixed post.
            # Refreshing an already selected video does not rediscover images.
            image_error = error if isinstance(error, core.SafeExtractionFailure) else core.classify_extraction_error(error)
            if image_error.code in {"private_media", "login_required", "age_restriction", "service_challenge", "incomplete_post", "identity_mismatch", "invalid_identity"}:
                raise image_error
            if not av and av_error: raise av_error
            raise image_error
    result = av + images
    if not result:
        if av_error: raise av_error
        fail("no_media", "No supported media was found. Profiles and ongoing live streams are not imported.")
    return result


def selected(request):
    identity = request.get("identity")
    if not isinstance(identity, dict): fail("identity_required", "The selected media identity is missing.")
    records = inventory(request)
    matches = [r for r in records if r[0]["source_identity"] == identity]
    if len(matches) != 1: fail("identity_changed", "The selected post asset changed or is no longer available.")
    metadata, info, formats = matches[0]
    expected = request.get("asset_fingerprint")
    if expected is not None and not info.get("needsContentFingerprint") and metadata.get("asset_fingerprint") != expected:
        fail("identity_changed", "The selected image changed. Review this post again.")
    return metadata, info, formats


def handle(request):
    action = request["action"]
    if action == "validate_account_session":
        site, _ = webpage(request.get("url"))
        if site == "youtube":
            with core.illucet_accounts.downloader({"account_cookies":request.get("site_cookies")}, YoutubeDL, core._options(core._SafeLogger())):
                return {"verified": True}
        if site == "instagram":
            import instaloader
            loader = instaloader.Instaloader(quiet=True, sleep=False, max_connection_attempts=1)
            try:
                for cookie in cookie_jar(request, site): loader.context._session.cookies.set_cookie(cookie)
                if not loader.test_login(): fail("session_unverified", "Instagram did not confirm this session. Check your connection or sign in again.")
                return {"verified": True}
            finally:
                loader.context._session.cookies.clear(); loader.close()
        if site == "reddit":
            import requests
            import illucet_images
            with requests.Session() as session:
                for cookie in cookie_jar(request, site): session.cookies.set_cookie(cookie)
                session.headers["User-Agent"] = "Illucet/1.0 (on-device media client)"
                try:
                    value = illucet_images._get(session, "https://www.reddit.com/api/me.json", fail, check_cancelled)
                    if not value.get("data", {}).get("name"): fail("session_expired", "Reddit did not accept this session. Sign in again.")
                    return {"verified": True}
                finally: session.cookies.clear()
        fail("session_unverified", "This website can verify the saved session when an authenticated download succeeds.")
    if action == "extract_post":
        assets = [record[0] for record in inventory(request)]
        return {"assets":assets}
    metadata, info, formats = selected(request)
    if action == "extract_asset": return metadata
    if action == "resolve_asset":
        if metadata["source_identity"]["kind"] == "image":
            raw = info; format_id = "original"; has_video = has_audio = False
        else:
            format_id = request.get("format_id")
            matches = [f for f in formats if str(f.get("format_id")) == format_id and not f.get("has_drm")]
            if len(matches) != 1: fail("format_unavailable", "The exact selected format is unavailable.")
            raw = matches[0]
            fact = next(f for f in metadata["formats"] if f["format_id"] == format_id)
            has_video, has_audio = fact["has_video"], fact["has_audio"]
        credential_headers = {str(k).lower() for k in (raw.get("http_headers") or {})}
        if credential_headers & {"authorization", "proxy-authorization"}:
            fail("authenticated_transport_unsupported", "This format uses an unsupported authorization header.")
        requires_python = bool(raw.get("cookies")) or "cookie" in credential_headers
        if metadata["source_identity"]["site"] == "youtube":
            core.illucet_accounts.validate_media_transport(raw)
        protocol = str(raw.get("protocol") or ("https" if metadata["source_identity"]["kind"] == "image" else ""))
        return {"identity":metadata["source_identity"], "formatID":format_id,
                "url":transport_url(raw.get("url")), "headers":core._resolved_headers(raw.get("http_headers")),
                "fileExtension":raw.get("ext"), "protocolName":protocol,
                "hasVideo":has_video, "hasAudio":has_audio,
                "needsContentFingerprint":bool(raw.get("needsContentFingerprint")),
                "expectedBytes":core._finite_number(raw.get("filesize"), integral=True), "requiresPython":requires_python}
    if action == "download_asset":
        root = Path(request.get("directory", ""))
        job_id = request.get("job_id", "")
        if root.name != "Illucet-"+job_id or root.is_symlink() or not root.is_dir() or root.resolve() != root.absolute():
            fail("unsafe_destination", "The download directory is invalid.")
        format_id = request.get("format_id")
        matches = [f for f in formats if str(f.get("format_id")) == format_id and not f.get("has_drm")]
        if len(matches) != 1: fail("format_unavailable", "The exact selected format is unavailable.")
        raw = matches[0]
        if raw.get("protocol") not in {"http","https","m3u8_native","http_dash_segments"}:
            fail("unsupported_transport", "This transport requires an unavailable external download program.")
        destination = root / ("python-"+hashlib.sha256(format_id.encode()).hexdigest()[:24]+".media")
        for candidate in root.glob(destination.name+"*"):
            if candidate.is_symlink() or not candidate.is_file():
                fail("unsafe_destination", "The download destination contains an unsafe file.")
            candidate.unlink()
        opts = options(request, metadata["source_identity"]["site"])
        def progress(event):
            check_cancelled()
            if event.get("status") == "downloading":
                _illucet_native.emit_json(json.dumps({"kind":"asset_progress", "payload":{"job_id":job_id,
                    "bytes":event.get("downloaded_bytes",0), "total":event.get("total_bytes")}},separators=(",",":")))
        opts.update(skip_download=False, simulate=False, continuedl=False, nopart=False,
                    cachedir=False, writesubtitles=False, writeinfojson=False,
                    postprocessors=[], progress_hooks=[progress], hls_prefer_native=True,
                    external_downloader=None, fragment_retries=1, retries=1, _no_ytdl_file=True)
        from yt_dlp.downloader import get_suitable_downloader
        with YoutubeDL(opts) as ydl:
            for cookie in cookie_jar(request, metadata["source_identity"]["site"]): ydl.cookiejar.set_cookie(cookie)
            # Upstream parses and domain-scopes its own cookie transport facts.
            # They stay in this in-process request, never a Swift descriptor,
            # background task, cookie file or info JSON.
            raw = dict(raw)
            raw["http_headers"] = ydl._calc_headers(raw, load_cookies=True)
            downloader_type = get_suitable_downloader(raw, ydl.params)
            if downloader_type.__module__.endswith("external"):
                fail("unsupported_transport", "This transport requires an external program.")
            try:
                check_cancelled()
                downloader = downloader_type(ydl, ydl.params)
                downloader.add_progress_hook(progress)
                downloader.download(str(destination), dict(raw, id=metadata["video_id"]))
                check_cancelled()
                if destination.is_symlink() or not destination.is_file() or destination.stat().st_size <= 0:
                    fail("invalid_output", "The downloader produced no complete regular file.")
                return {"filename":destination.name, "bytes":destination.stat().st_size}
            except BaseException:
                destination.unlink(missing_ok=True)
                raise
            finally:
                ydl.cookiejar.clear()
                for partial in root.glob(destination.name+"*"):
                    if partial != destination and partial.is_file() and not partial.is_symlink(): partial.unlink(missing_ok=True)
    fail("unsupported_action", "Unknown media operation.")
