"""Extract only the exact post supplied by Reddit's ordinary browser page."""
from __future__ import annotations

import hashlib
import json
import re
from html.parser import HTMLParser
from urllib.parse import urlsplit, urlunsplit

from yt_dlp.extractor.common import InfoExtractor


def validate_webpage(url, fail):
    parts = urlsplit(url)
    if re.search(r"/(?:comments|gallery)/[a-z0-9]{3,16}(?:/|$)", parts.path, re.I): return
    if parts.hostname == "redd.it" and re.fullmatch(r"/[a-z0-9]{3,16}/?", parts.path, re.I): return
    if re.fullmatch(r"/r/[^/]+/s/[a-zA-Z0-9]+/?", parts.path): return
    fail("collection_unsupported", "Import an individual Reddit post, not a profile or community.")


class PostParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.posts = []
        self.players = []
        self.links = []
        self.gated = False
        self.gallery_depth = 0
        self.gallery_images = []

    def handle_starttag(self, tag, attributes):
        values = dict(attributes)
        if tag == "gallery-carousel": self.gallery_depth += 1
        elif tag == "img" and self.gallery_depth and values.get("src"):
            self.gallery_images.append(values["src"])
        elif tag == "shreddit-post": self.posts.append(values)
        elif tag == "shreddit-player": self.players.append(values)
        elif tag == "a" and self.gallery_depth and values.get("href"): self.links.append(values["href"])
        elif tag == "shreddit-content-gate": self.gated = True

    def handle_endtag(self, tag):
        if tag == "gallery-carousel": self.gallery_depth = max(0, self.gallery_depth - 1)


def post(request, fail):
    page = request.get("reddit_page")
    if not isinstance(page, dict):
        fail("reddit_browser_required", "Reddit requires its browser page for this post.")
    errors = {
        "private_media": "This Reddit community requires an account with access.",
        "age_restriction": "This Reddit post requires an eligible signed-in account.",
        "login_required": "Reddit requires sign-in to view this post.",
        "service_challenge": "Reddit could not open this post on this connection. Try opening it in your browser.",
        "invalid_response": "This Reddit post exceeds the supported page size.",
    }
    if page.get("error") in errors: fail(page["error"], errors[page["error"]])
    source = page.get("html")
    if not isinstance(source, str) or not 0 < len(source.encode()) <= 300_000:
        fail("invalid_response", "Reddit did not return a supported post page.")
    parser = PostParser()
    parser.feed(source)
    if len(parser.posts) != 1: fail("identity_mismatch", "Reddit returned an ambiguous post page.")
    attributes = parser.posts[0]
    if parser.gated or ("nsfw" in attributes and not request.get("site_cookies")):
        fail("age_restriction", "This Reddit post requires an eligible signed-in account.")
    identifier = attributes.get("id", "")
    if not re.fullmatch(r"t3_[a-z0-9]{3,16}", identifier):
        fail("identity_mismatch", "Reddit did not identify this post.")
    post_id = identifier[3:]
    expected = re.search(r"/(?:comments|gallery)/([a-z0-9]+)(?:/|$)", urlsplit(request["url"]).path, re.I)
    permalink = attributes.get("permalink", "")
    returned = re.search(r"/comments/([a-z0-9]+)(?:/|$)", urlsplit(permalink).path)
    if (expected and expected[1].lower() != post_id) or not returned or returned[1] != post_id:
        fail("identity_mismatch", "Reddit returned a different post.")
    return post_id, attributes, parser


def video_info(request, ydl, fail, check):
    post_id, attributes, parser = post(request, fail)
    if not parser.players: return {"id": post_id, "entries": []}
    if len(parser.players) != 1: fail("no_media", "This Reddit post has an unsupported video layout.")
    player = parser.players[0]
    if player.get("post-id") not in (post_id, "t3_" + post_id):
        fail("identity_mismatch", "The Reddit player belongs to another post.")
    try: packaged = json.loads(player.get("packaged-media-json", "{}"))
    except ValueError: fail("invalid_response", "Reddit returned an invalid video record.")
    if not isinstance(packaged, dict): fail("invalid_response", "Reddit returned an invalid video record.")
    playback = packaged.get("playbackMp4s", {})
    if not isinstance(playback, dict): fail("invalid_response", "Reddit returned an invalid video record.")
    permutations = playback.get("permutations", [])
    if not isinstance(permutations, list) or len(permutations) > 100:
        fail("invalid_response", "Reddit returned too many video variants.")
    formats = []
    for permutation in permutations:
        check()
        source = permutation.get("source", {}) if isinstance(permutation, dict) else {}
        if not isinstance(source, dict) or not media_url(source.get("url")): continue
        dimensions = source.get("dimensions", {})
        if not isinstance(dimensions, dict): continue
        height, width = dimensions.get("height"), dimensions.get("width")
        bitrate = source.get("bitrateBps")
        facts = [height, width, bitrate, source.get("videoCodec")]
        format_id = "reddit-" + hashlib.sha256(json.dumps(facts).encode()).hexdigest()[:24]
        formats.append({"format_id": format_id, "url": source["url"],
            "protocol": "https", "ext": "mp4", "height": height, "width": width,
            "tbr": bitrate / 1000 if isinstance(bitrate, (int, float)) else None})
    manifest = player.get("src", "")
    extractor = InfoExtractor(ydl)
    if media_url(manifest) and urlsplit(manifest).path.endswith(".m3u8"):
        formats.extend(extractor._extract_m3u8_formats(manifest, post_id, "mp4", m3u8_id="reddit-hls", fatal=False))
    elif media_url(manifest) and urlsplit(manifest).path.endswith(".mpd"):
        formats.extend(extractor._extract_mpd_formats(manifest, post_id, mpd_id="reddit-dash", fatal=False))
    reference = urlsplit(attributes.get("content-href", ""))
    if not reference.hostname or reference.scheme != "https":
        fail("identity_mismatch", "Reddit did not identify the post's original media.")
    stable_reference = urlunsplit((reference.scheme, reference.netloc.lower(), reference.path, "", ""))
    asset_id = hashlib.sha256(stable_reference.encode()).hexdigest()[:32]
    return {"id": post_id, "entries": [{"id": asset_id, "title": attributes.get("post-title"),
        "uploader": attributes.get("author"), "webpage_url": request["url"],
        "duration": playback.get("duration"), "formats": formats}]}


def media_url(value):
    if not isinstance(value, str) or len(value.encode()) > 16_384: return False
    try: parts = urlsplit(value)
    except ValueError: return False
    return parts.scheme == "https" and not parts.username and not parts.password and parts.hostname in {
        "v.redd.it", "packaged-media.redd.it", "preview.redd.it", "external-preview.redd.it"}


def images(request, fail, check):
    post_id, attributes, parser = post(request, fail)
    if parser.players and attributes.get("post-type") != "gallery": return []
    candidates = [attributes.get("content-href", "")]
    if attributes.get("post-type") == "gallery": candidates.extend(parser.links + parser.gallery_images)
    records = []
    seen = set()
    for address in candidates:
        check()
        parts = urlsplit(address)
        if parts.scheme != "https" or parts.hostname != "i.redd.it" or parts.username or parts.password: continue
        match = re.fullmatch(r"/([a-zA-Z0-9_-]+)\.(jpg|jpeg|png|webp|gif|avif)", parts.path)
        if not match or match[1] in seen: continue
        seen.add(match[1])
        records.append({"post": post_id, "asset": match[1], "url": address, "title": attributes.get("post-title")})
    return records
