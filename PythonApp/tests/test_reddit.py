import html
import json
import unittest

import test_ytdlp_extractor
import illucet_multisite as media
import illucet_reddit as reddit


def page(post="abc123", player_post="t3_abc123", reference="https://v.redd.it/video123", sources=None):
    sources = sources or [{"source": {"url": "https://packaged-media.redd.it/video123/480.mp4?token=one",
        "dimensions": {"height": 480, "width": 854}, "bitrateBps": 400000, "videoCodec": "avc1"}}]
    packaged = html.escape(json.dumps({"playbackMp4s": {"duration": 12, "permutations": sources}}), quote=True)
    return {"url": "https://www.reddit.com/r/example/comments/abc123/post/", "reddit_page": {"html":
        f'<shreddit-post id="t3_{post}" permalink="/r/example/comments/{post}/post/" post-title="Post" '
        f'content-href="{reference}"><shreddit-player post-id="{player_post}" '
        f'packaged-media-json="{packaged}"></shreddit-player></shreddit-post>'}}


class RedditTests(unittest.TestCase):
    def test_uses_exact_post_and_player_binding(self):
        info = reddit.video_info(page(), object(), media.fail, lambda: None)
        self.assertEqual(info["id"], "abc123")
        self.assertEqual(len(info["entries"][0]["formats"]), 1)
        for request in [page(post="other"), page(player_post="t3_other")]:
            with self.assertRaises(media.core.SafeExtractionFailure) as failure:
                reddit.video_info(request, object(), media.fail, lambda: None)
            self.assertEqual(failure.exception.code, "identity_mismatch")

    def test_variant_order_and_signed_queries_preserve_identity(self):
        first = page()
        source = {"source": {"url": "https://packaged-media.redd.it/video123/720.mp4?token=one",
            "dimensions": {"height": 720, "width": 1280}, "bitrateBps": 800000, "videoCodec": "avc1"}}
        original = reddit.video_info(first, object(), media.fail, lambda: None)["entries"][0]
        other = page(reference="https://v.redd.it/video123?token=two", sources=[source,
            {"source": {"url": "https://packaged-media.redd.it/video123/480.mp4?token=two",
                "dimensions": {"height": 480, "width": 854}, "bitrateBps": 400000, "videoCodec": "avc1"}}])
        refreshed = reddit.video_info(other, object(), media.fail, lambda: None)["entries"][0]
        self.assertEqual(original["id"], refreshed["id"])
        self.assertEqual(original["formats"][0]["format_id"], refreshed["formats"][1]["format_id"])
        changed = reddit.video_info(page(reference="https://v.redd.it/another"), object(), media.fail, lambda: None)
        self.assertNotEqual(original["id"], changed["entries"][0]["id"])

    def test_private_and_challenge_responses_stay_distinct(self):
        for code in ["private_media", "login_required", "age_restriction", "service_challenge"]:
            with self.assertRaises(media.core.SafeExtractionFailure) as failure:
                media.inventory({"url": "https://reddit.com/comments/abc123", "reddit_page": {"error": code}})
            self.assertEqual(failure.exception.code, code)

    def test_rejects_ambiguous_or_oversized_pages_and_untrusted_transports(self):
        for body in ["x" * 300001, '<shreddit-post id="t3_abc123"></shreddit-post>' * 2]:
            with self.assertRaises(media.core.SafeExtractionFailure):
                reddit.post({"url": "https://reddit.com/comments/abc123", "reddit_page": {"html": body}}, media.fail)
        for url in ["file:///tmp/movie.mp4", "https://127.0.0.1/video", "https://user:secret@v.redd.it/video", "https://v.redd.it.evil.example/video"]:
            self.assertFalse(reddit.media_url(url))

    def test_images_use_original_post_assets_and_exclude_previews(self):
        request = {"url": "https://reddit.com/gallery/abc123", "reddit_page": {"html":
            '<shreddit-post id="t3_abc123" permalink="/r/example/comments/abc123/post/" post-type="gallery">'
            '<gallery-carousel>'
            '<a href="https://i.redd.it/photo1.jpg">Original</a>'
            '<a href="https://i.redd.it/photo2.png">Original</a>'
            '<a href="https://i.redd.it/photo1.jpg">Duplicate</a>'
            '<img src="https://preview.redd.it/preview.jpg?width=100">'
            '<img src="https://i.redd.it/photo3.jpg"></gallery-carousel>'
            '<img src="https://i.redd.it/unrelated.jpg">'
            '<a href="https://i.redd.it/unrelated_link.jpg">Caption link</a>'
            '<a href="https://preview.redd.it/photo3.jpg?width=100">Preview</a></shreddit-post>'}}
        images = reddit.images(request, media.fail, lambda: None)
        self.assertEqual([image["asset"] for image in images], ["photo1", "photo2", "photo3"])
        self.assertTrue(all(image["post"] == "abc123" for image in images))

    def test_requests_browser_before_using_account_credentials(self):
        with self.assertRaises(media.core.SafeExtractionFailure) as failure:
            media.inventory({"url": "https://reddit.com/comments/abc123"})
        self.assertEqual(failure.exception.code, "reddit_browser_required")

    def test_collection_links_and_age_gates_require_review(self):
        with self.assertRaises(media.core.SafeExtractionFailure) as failure:
            media.inventory({"url": "https://reddit.com/r/example/"})
        self.assertEqual(failure.exception.code, "collection_unsupported")
        request = page()
        request["reddit_page"]["html"] = request["reddit_page"]["html"].replace('<shreddit-post ', '<shreddit-post nsfw ')
        with self.assertRaises(media.core.SafeExtractionFailure) as failure:
            reddit.post(request, media.fail)
        self.assertEqual(failure.exception.code, "age_restriction")
