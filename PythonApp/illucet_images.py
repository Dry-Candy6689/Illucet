"""Original post-image adapters. No gallery-dl code, configs, or disk sessions.

Identity comes from a service's post record and media IDs/order. Transport stays
request-local; these adapters never turn video thumbnails into image downloads.
"""
from __future__ import annotations

import html
import json
import re
from html.parser import HTMLParser
from urllib.parse import urlsplit, urlencode, parse_qs


class _PageData(HTMLParser):
    """Read only structured page data; never collect arbitrary page images."""
    def __init__(self):
        super().__init__()
        self.values, self.parts = [], None

    def handle_starttag(self, tag, attrs):
        if tag == "script" and dict(attrs).get("type") == "application/json":
            self.parts = []

    def handle_data(self, value):
        if self.parts is not None: self.parts.append(value)

    def handle_endtag(self, tag):
        if tag == "script" and self.parts is not None:
            try: self.values.append(json.loads("".join(self.parts)))
            except (ValueError, RecursionError): pass
            self.parts = None


def _objects(value):
    pending = [value]
    while pending:
        item = pending.pop()
        if isinstance(item, dict):
            yield item
            pending.extend(reversed(list(item.values())))
        elif isinstance(item, list): pending.extend(reversed(item))


def _facebook_photo(values, identifier, fail):
    # currMedia binds the photo viewer to the requested ID. Adjacent photos,
    # avatars, recommendations and comment attachments are never eligible.
    matches = [obj["currMedia"] for obj in _objects(values)
               if isinstance(obj.get("currMedia"), dict)
               and obj["currMedia"].get("__typename") == "Photo"
               and str(obj["currMedia"].get("id")) == identifier]
    records = []
    for photo in matches:
        source = photo.get("image") or {}
        if source.get("uri"):
            records.append(_image(identifier, identifier, source["uri"],
                photo.get("accessibility_caption"), source.get("width"), source.get("height")))
    if not records: fail("image_source_unavailable", "Facebook did not provide this photo. Sign in if it requires account access.")
    if len({r["url"] for r in records}) != 1:
        fail("identity_mismatch", "Facebook returned conflicting photo records.")
    return records[0]


def _facebook(url, ydl, fail, check):
    extractor = ydl.get_info_extractor("Facebook"); extractor.initialize()
    def page(address, identifier):
        check()
        body, response = extractor._download_webpage_handle(address, identifier)
        final = urlsplit(response.url)
        if not (final.hostname == "facebook.com" or (final.hostname or "").endswith(".facebook.com")):
            fail("identity_mismatch", "Facebook redirected to another website.")
        if final.path.startswith(("/login", "/checkpoint")):
            fail("login_required", "Facebook requires sign-in for this post.")
        if len(body.encode()) > 8 * 1024 * 1024:
            fail("invalid_response", "The Facebook post exceeds the supported size.")
        data = _PageData(); data.feed(body)
        return data.values

    parts = urlsplit(url)
    identifier = (parse_qs(parts.query).get("fbid") or [None])[0]
    photo = re.fullmatch(r"/[^/]+/photos/(?:[^/]+/)?(\d+)/?", parts.path)
    if identifier or photo:
        identifier = identifier or photo[1]
        return [_facebook_photo(page(url, identifier), identifier, fail)]
    post = re.search(r"/(?:posts|permalink)/([A-Za-z0-9]+)/?", parts.path)
    identifier = post[1] if post else (parse_qs(parts.query).get("story_fbid") or [None])[0]
    if not identifier: return []  # Ordinary video/reel routes use yt-dlp.
    values = page(url, identifier)
    stories = [v for v in _objects(values) if str(v.get("post_id")) == identifier]
    if not stories: fail("image_source_unavailable", "Facebook did not provide the requested post's photo inventory.")
    ids = []
    for story in stories:
        for obj in _objects(story.get("attachments", [])):
            if obj.get("page_info", {}).get("has_next_page") is True:
                fail("incomplete_post", "Facebook supplied only part of this gallery. Import individual photo links.")
            if obj.get("__typename") == "Photo" and re.fullmatch(r"\d+", str(obj.get("id", ""))):
                if obj["id"] not in ids: ids.append(obj["id"])
    if len(ids) > 50: fail("too_many_assets", "Select a Facebook post with at most 50 photos.")
    records = []
    for photo_id in ids:
        record = _facebook_photo(page("https://www.facebook.com/photo.php?" + urlencode({"fbid":photo_id}), photo_id), photo_id, fail)
        record["post"] = identifier
        records.append(record)
    return records


def _get(session, url, fail, check):
    check()
    with session.get(url, timeout=15, stream=True) as response:
        if response.status_code == 401:
            fail("login_required", "This post requires sign-in.")
        if response.status_code == 429:
            fail("service_challenge", "The website is limiting this connection. Try again later.")
        data = bytearray()
        for chunk in response.iter_content(64 * 1024):
            check(); data.extend(chunk)
            if len(data) > 8 * 1024 * 1024:
                fail("invalid_response", "The post response exceeds the supported size.")
        if response.status_code == 403:
            try: reason = json.loads(data).get("reason")
            except (ValueError, AttributeError): reason = None
            if reason in {"private", "quarantined"}:
                fail("private_media", "This post requires an account with access.")
            fail("service_challenge", "The website refused this connection. Try again later.")
        if response.status_code >= 400:
            fail("post_unavailable", "This post is unavailable.")
        return json.loads(data)


def _image(post, asset, url, title=None, width=None, height=None):
    return {"post": str(post), "asset": str(asset), "url": html.unescape(url),
            "title": title, "width": width, "height": height}


def _instagram(request, url, jar, fail):
    import instaloader
    match = re.search(r"/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)/?", urlsplit(url).path)
    if not match: fail("collection_unsupported", "Import an individual Instagram post or Reel.")
    loader = instaloader.Instaloader(quiet=True, sleep=False, max_connection_attempts=1,
        download_pictures=False, download_videos=False, download_video_thumbnails=False,
        download_geotags=False, download_comments=False, save_metadata=False)
    try:
        session = loader.context._session
        for cookie in jar: session.cookies.set_cookie(cookie)
        if any(cookie.name == "sessionid" for cookie in jar):
            loader.context.username = "saved-session"
        post = instaloader.Post.from_shortcode(loader.context, match[1])
        if post.shortcode != match[1]: fail("identity_mismatch", "Instagram returned a different post.")
        if post.typename == "GraphSidecar":
            post._obtain_metadata()
            raw = post._node.get("edge_sidecar_to_children", {}).get("edges", [])
            nodes = list(post.get_sidecar_nodes())
            if len(raw) != len(nodes):
                fail("incomplete_post", "Instagram returned an incomplete gallery. Try this post again.")
            result = []
            for index, node in enumerate(nodes):
                if node.is_video: continue
                fact = raw[index].get("node", {}) if index < len(raw) else {}
                # The API array index is post-relative identity when no media ID
                # is exposed; the caller adds a transport change fence.
                identity = fact.get("id") or f"item-{index + 1}"
                result.append(_image(post.mediaid, identity, node.display_url, post.caption))
            return result
        if post.is_video: return []
        return [_image(post.mediaid, post.mediaid, post.url, post.caption)]
    except (instaloader.LoginRequiredException, instaloader.PrivateProfileNotFollowedException):
        fail("login_required", "Instagram requires an account with access to this post.")
    except instaloader.TooManyRequestsException:
        fail("service_challenge", "Instagram is limiting this connection. Try again later.")
    finally:
        loader.context._session.cookies.clear()
        loader.close()


def extract(request, site, url, ydl, jar, fail, check):
    """Return original-image records, or a truthful service/access failure."""
    if site == "instagram": return _instagram(request, url, jar, fail)
    if site == "facebook": return _facebook(url, ydl, fail, check)
    if site == "reddit" and request.get("reddit_page") is not None:
        import illucet_reddit
        return illucet_reddit.images(request, fail, check)
    import requests
    with requests.Session() as session:
        session.headers["User-Agent"] = "Illucet/1.0 (on-device media client)"
        for cookie in jar: session.cookies.set_cookie(cookie)
        try:
            if site == "reddit":
                match = re.search(r"/comments/([A-Za-z0-9]+)", urlsplit(url).path)
                if not match: fail("collection_unsupported", "Import the Reddit post link, not a profile or community.")
                identifier = match[1]
                value = _get(session, f"https://www.reddit.com/comments/{identifier}/.json?raw_json=1", fail, check)
                data = value[0]["data"]["children"][0]["data"]
                if data.get("id") != identifier: fail("identity_mismatch", "Reddit returned another post.")
                result = []
                for item in data.get("gallery_data", {}).get("items", []):
                    media_id = item.get("media_id")
                    meta = data.get("media_metadata", {}).get(media_id, {})
                    source = meta.get("s", {})
                    original = source.get("gif") or source.get("u")
                    if original and meta.get("e") in {"Image", "AnimatedImage"}:
                        result.append(_image(identifier, media_id, original, data.get("title"), source.get("x"), source.get("y")))
                if not result and data.get("post_hint") == "image":
                    original = data.get("url_overridden_by_dest") or data.get("url")
                    if original: result.append(_image(identifier, "post-image", original, data.get("title")))
                return result
            if site == "bluesky":
                match = re.fullmatch(r"/profile/([^/]+)/post/([^/]+)/?", urlsplit(url).path)
                if not match: fail("collection_unsupported", "Import an individual Bluesky post.")
                actor, key = match.groups()
                if not actor.startswith("did:"):
                    actor = _get(session, "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?" + urlencode({"handle": actor}), fail, check)["did"]
                uri = f"at://{actor}/app.bsky.feed.post/{key}"
                post = _get(session, "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?" + urlencode({"uri": uri, "depth": 0}), fail, check)["thread"]["post"]
                if post.get("uri") != uri: fail("identity_mismatch", "Bluesky returned another post.")
                embed = post.get("record", {}).get("embed", {})
                if embed.get("$type") == "app.bsky.embed.recordWithMedia": embed = embed.get("media", {})
                result = []
                images = embed.get("images", [])
                endpoint = None
                if images:
                    did_doc = _get(session, "https://plc.directory/" + actor, fail, check) if actor.startswith("did:plc:") else None
                    if not did_doc or did_doc.get("id") != actor:
                        fail("image_source_unavailable", "The original Bluesky image server could not be verified.")
                    services = did_doc.get("service", [])
                    endpoint = next((s.get("serviceEndpoint") for s in services
                        if s.get("id") in {"#atproto_pds", actor + "#atproto_pds"}
                        and s.get("type") == "AtprotoPersonalDataServer"), None)
                    if not endpoint or urlsplit(endpoint).scheme != "https":
                        fail("image_source_unavailable", "The original Bluesky image server could not be resolved.")
                for item in images:
                    blob = item.get("image", {})
                    cid = blob.get("ref", {}).get("$link")
                    if cid:
                        # Fetch the referenced source blob, not a thumbnail/CDN
                        # resize. resolveHandle's DID is also part of identity.
                        original = endpoint.rstrip("/") + "/xrpc/com.atproto.sync.getBlob?" + urlencode({"did": actor, "cid": cid})
                        result.append(_image(uri, cid, original, item.get("alt") or post["record"].get("text")))
                    else: fail("incomplete_post", "Bluesky returned a photo without its source identity.")
                return result
            if site == "x":
                match = re.search(r"/status/(\d+)", urlsplit(url).path)
                if not match: fail("collection_unsupported", "Import an individual X post.")
                extractor = ydl.get_info_extractor("Twitter"); extractor.initialize()
                status = extractor._extract_status(match[1])
                if str(status.get("id_str") or status.get("id")) != match[1]:
                    fail("identity_mismatch", "X returned another post.")
                result = []
                for item in status.get("extended_entities", {}).get("media", []):
                    if item.get("type") != "photo": continue
                    media_id = item.get("id_str") or item.get("id")
                    original = item.get("media_url_https")
                    if media_id and original:
                        # X's media record authorizes its original-size variant.
                        original += "&name=orig" if "?" in original else "?name=orig"
                        result.append(_image(match[1], media_id, original, status.get("full_text")))
                return result
            if site == "tiktok":
                match = re.search(r"/(?:photo|video)/(\d+)", urlsplit(url).path)
                if not match: fail("collection_unsupported", "Import the full TikTok photo-post link.")
                extractor = ydl.get_info_extractor("TikTok"); extractor.initialize()
                # TikTok's photo route can return only the app shell. Its public
                # video route exposes the same post record, including imagePost.
                detail_url = url.replace("/photo/", "/video/")
                item, status = extractor._extract_web_data_and_status(detail_url, match[1])
                if status != 0: fail("post_unavailable", "TikTok did not make this post available.")
                if not isinstance(item, dict):
                    fail("service_challenge", "TikTok did not provide the post data. Try again later.")
                if str(item.get("id")) != match[1]: fail("identity_mismatch", "TikTok returned another post.")
                result = []
                for index, image in enumerate(item.get("imagePost", {}).get("images", [])):
                    source = image.get("imageURL", {})
                    urls = source.get("urlList") or []
                    if not urls: fail("incomplete_post", "TikTok did not supply every photo in this slideshow.")
                    result.append(_image(match[1], image.get("imageId") or f"item-{index + 1}", urls[0], item.get("desc"), image.get("imageWidth"), image.get("imageHeight")))
                return result
            if site == "pinterest":
                match = re.search(r"/pin/(\d+)", urlsplit(url).path)
                if not match: fail("collection_unsupported", "Import the full Pinterest pin link.")
                extractor = ydl.get_info_extractor("Pinterest"); extractor.initialize()
                data = extractor._call_api("Pin", match[1], {"field_set_key": "unauth_react_main_pin", "id": match[1]})["data"]
                if str(data.get("id")) != match[1]: fail("identity_mismatch", "Pinterest returned another pin.")
                if data.get("videos") or data.get("story_pin_data"): return []
                original = data.get("images", {}).get("orig", {})
                if original.get("url"):
                    return [_image(match[1], "pin-image", original["url"], data.get("title") or data.get("description"), original.get("width"), original.get("height"))]
                return []
            return []
        finally:
            session.cookies.clear()
