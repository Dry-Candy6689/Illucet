"""Regression coverage for multi-site identities and ephemeral transport."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import test_ytdlp_extractor  # installs the deterministic native bridge stub
import illucet_multisite as media
import illucet_bridge
import illucet_ytdlp_provider as provider
import http.cookiejar
import struct
from urllib.error import HTTPError


IDENTITY = {"site":"vimeo", "postID":"1234", "assetID":"1234", "kind":"video"}
FORMAT = {"format_id":"original", "ext":"mp4", "protocol":"https", "vcodec":"h264", "acodec":"aac",
          "url":"https://cdn.example.org/movie.mp4?token=transport-secret", "width":320, "height":180}
INFO = {"id":"1234", "title":"Example", "webpage_url":"https://vimeo.com/1234", "formats":[FORMAT]}


class FakeYDL:
    def __init__(self, options): self.options=options; self.cookiejar=http.cookiejar.CookieJar()
    def __enter__(self): return self
    def __exit__(self,*args): pass
    def extract_info(self,url,download):
        assert download is False
        return copy.deepcopy(INFO)


class MultiSiteTests(unittest.TestCase):
    def test_wrapped_http_failures_are_typed_without_exposing_request_secrets(self):
        for status, code in [(401,"service_challenge"),(403,"service_challenge"),(404,"post_unavailable"),(429,"service_challenge"),(503,"network_failure")]:
            cause = HTTPError("https://cdn.example/file?token=secret",status,"Refused",{},None)
            error = media.core.DownloadError("Request failed", (type(cause),cause,None))
            failure = media.core.classify_extraction_error(error)
            self.assertEqual(failure.code,code)
            self.assertNotIn("secret",failure.message)
            cause.close()
        private_cause = HTTPError("https://example.org",403,"Refused",{},None)
        private = media.core.ExtractorError("This video is private", cause=private_cause)
        self.assertEqual(media.core.classify_extraction_error(private).code,"private_media")
        private_cause.close()
    def test_unexpected_asset_failure_keeps_only_redacted_trace_shape(self):
        with patch.object(media, "handle", side_effect=TypeError("https://cdn.example/file?token=secret")), patch.object(media._illucet_native, "emit_json") as emit:
            result = json.loads(illucet_bridge.handle_request(json.dumps({"action":"extract_asset","url":"https://vimeo.com/1234"})))
        self.assertFalse(result["ok"])
        events = [json.loads(call.args[0]) for call in emit.call_args_list]
        failure = next(value for value in events if value["kind"] == "asset_failure")
        self.assertEqual(failure["payload"]["exception_type"], "TypeError")
        self.assertEqual(failure["payload"]["stage"], "dispatch_asset")
        self.assertNotIn("secret", json.dumps(events))

    def test_preserves_engine_cookiejar_protocol(self):
        from yt_dlp import YoutubeDL
        def extract(ydl,url,download):
            self.assertTrue(callable(ydl.cookiejar.get_cookie_header))
            return copy.deepcopy(INFO)
        with patch.object(YoutubeDL,"extract_info",extract):
            result=media.av_assets({},"vimeo","https://vimeo.com/1234")
            self.assertEqual(len(result),1)
    def test_webpage_scope_and_tracking_cleanup(self):
        self.assertEqual(media.webpage("https://x.com/person/status/123?utm_source=abc#fragment"),
                         ("x","https://x.com/person/status/123"))
        for url in ("https://x.com.evil.test/status/123", "file:///tmp/a", "https://person:secret@x.com/status/123", "https://127.0.0.1/a"):
            with self.assertRaises(media.core.SafeExtractionFailure): media.webpage(url)

    def test_metadata_never_contains_transport(self):
        with patch.object(media,"YoutubeDL",FakeYDL):
            data=media.handle({"action":"extract_post","url":"https://vimeo.com/1234"})
        self.assertEqual(data["assets"][0]["source_identity"],IDENTITY)
        self.assertNotIn("transport-secret",json.dumps(data))
        self.assertNotIn("cdn.example.org",json.dumps(data))
        self.assertEqual(data["assets"][0]["formats"][0]["format_id"],"original")

    def test_exact_identity_and_format_are_required(self):
        request={"action":"resolve_asset","url":"https://vimeo.com/1234","identity":IDENTITY,"format_id":"original"}
        with patch.object(media,"YoutubeDL",FakeYDL):
            resolved=media.handle(request)
            self.assertEqual(resolved["identity"],IDENTITY)
            self.assertEqual(resolved["fileExtension"],"mp4")
            for modification in ({"format_id":"other"},{"identity":dict(IDENTITY,assetID="different")},{"identity":dict(IDENTITY,site="x")}):
                with self.assertRaises(media.core.SafeExtractionFailure): media.handle(dict(request,**modification))

    def test_wrong_site_cookies_are_rejected(self):
        with self.assertRaises(media.core.SafeExtractionFailure):
            media.cookie_jar({"site_cookies":[{"domain":".instagram.com","name":"sessionid","value":"secret"}]},"x")

    def test_local_transport_and_credential_headers_are_rejected(self):
        for value in ("http://localhost/a", "http://127.0.0.1/a", "http://192.168.1.2/a", "https://user:secret@cdn.example/a"):
            with self.assertRaises(media.core.SafeExtractionFailure): media.transport_url(value)
        with patch.object(media,"YoutubeDL",FakeYDL), patch.dict(FORMAT,http_headers={"Authorization":"Bearer secret"}):
            with self.assertRaises(media.core.SafeExtractionFailure):
                media.handle({"action":"resolve_asset","url":"https://vimeo.com/1234","identity":IDENTITY,"format_id":"original"})

    def test_gallery_ordinal_change_is_detected(self):
        metadata=media.media_metadata(dict(IDENTITY,site="instagram",kind="image"),"https://instagram.com/p/abc/",{},[])
        metadata["asset_fingerprint"]="a"*64
        with patch.object(media,"inventory",return_value=[(metadata,{},[])]):
            with self.assertRaises(media.core.SafeExtractionFailure):
                media.selected({"identity":metadata["source_identity"],"asset_fingerprint":"b"*64})

    def test_engine_preferences_are_request_local(self):
        prior=provider.active_engine_preferences.get()
        with patch.object(illucet_bridge,"_dispatch_request",side_effect=RuntimeError("fixture")):
            with self.assertRaises(RuntimeError):
                illucet_bridge.handle_request(json.dumps({"action":"fixture","engine_preferences":{"javaScript":"webKit"}}))
        self.assertEqual(provider.active_engine_preferences.get(),prior)

    def test_download_rejects_unowned_destination(self):
        with patch.object(media,"YoutubeDL",FakeYDL), tempfile.TemporaryDirectory() as root:
            with self.assertRaises(media.core.SafeExtractionFailure):
                media.handle({"action":"download_asset","url":"https://vimeo.com/1234","identity":IDENTITY,
                    "format_id":"original","directory":root,"job_id":"wrong"})

    def test_missing_codec_roles_come_from_container_tracks(self):
        def box(kind, body): return struct.pack(">I4s", len(body) + 8, kind) + body
        def track(role, entry):
            handler = box(b"hdlr", b"\0" * 8 + role)
            descriptor = box(b"stsd", b"\0" * 4 + struct.pack(">I", 1) + box(entry, b""))
            return box(b"trak", box(b"mdia", handler + box(b"minf", box(b"stbl", descriptor))))
        file = box(b"ftyp", b"isom") + box(b"moov", track(b"vide", b"avc1") + track(b"soun", b"mp4a"))
        self.assertEqual(media.mp4_codec_facts(file), {"vcodec":"h264", "acodec":"aac"})
        self.assertEqual(media.mp4_codec_facts(file[:-2]), {})
        self.assertEqual(media.mp4_codec_facts(b"not a video.mp4"), {})
        self.assertEqual(media.mp4_codec_facts(box(b"moov", track(b"vide", b"encv"))), {})
        self.assertIsNone(media.core._sanitize_format(dict(FORMAT, fps=0))["frames_per_second"])

    def test_stable_original_image_id_survives_signed_url_refresh(self):
        record = {"post":"post-1", "asset":"photo-2", "url":"https://cdn.example.org/original.jpg?token=old"}
        with patch("illucet_images.extract", return_value=[record]):
            initial = media.original_images({}, "instagram", "https://instagram.com/p/example")[0][0]
            record["url"] = "https://cdn.example.org/original.jpg?token=new"
            refreshed = media.original_images({}, "instagram", "https://instagram.com/p/example")[0][0]
            self.assertEqual(initial["source_identity"], refreshed["source_identity"])
            self.assertEqual(initial["asset_fingerprint"], refreshed["asset_fingerprint"])
            self.assertNotIn("token=", json.dumps(refreshed))
            record["asset"] = "item-2"
            ordinal = media.original_images({}, "instagram", "https://instagram.com/p/example")[0][0]
            record["url"] = "https://cdn.example.org/different.jpg?token=new"
            reordered = media.original_images({}, "instagram", "https://instagram.com/p/example")[0][0]
            self.assertNotEqual(ordinal["asset_fingerprint"], reordered["asset_fingerprint"])

    def test_reddit_image_fallback_preserves_explicit_access_failure(self):
        private = media.core.SafeExtractionFailure("private_media", "Private post")
        with patch.object(media, "av_assets", side_effect=private), patch.object(media, "original_images", side_effect=ValueError("fixture")):
            with self.assertRaises(media.core.SafeExtractionFailure) as caught:
                media.inventory({"url":"https://www.reddit.com/r/example/comments/abc123/post/", "reddit_page":{"html":"fixture"}})
        self.assertEqual(caught.exception.code, "private_media")

    def test_proof_provider_matches_exact_video_context_and_session(self):
        import time
        import illucet_potoken as proof
        from yt_dlp.extractor.youtube.pot.provider import PoTokenContext, PoTokenRequest, PoTokenProviderRejectedRequest
        provider = object.__new__(proof.IllucetPTP)
        request = PoTokenRequest(PoTokenContext.GVS, {"client":{"clientName":"MWEB"}}, video_id="dQw4w9WgXcQ", visitor_data="guest-one", _gvs_bind_to_video_id=True)
        scope = proof.begin({"engine_preferences":{"poTokens":"automatic"}})
        try:
            with self.assertRaises(PoTokenProviderRejectedRequest): provider._real_request_pot(request)
            failure = proof.finish_response('{"ok":false,"error":{"code":"no_compatible_format"}}')
            needed = json.loads(failure)["proof_request"]
            self.assertEqual(needed["videoID"], request.video_id)
            self.assertEqual(proof.finish_response('{"ok":true}'), '{"ok":true}')
            value = dict(needed, token="synthetic_" * 10, expires=time.time()+300)
            proof.active_request.get()["records"].append(value)
            with patch.object(media._illucet_native, "emit_json") as emit:
                self.assertEqual(provider._real_request_pot(request).po_token, value["token"])
                self.assertNotIn(value["token"], str(emit.call_args))
            request.visitor_data = "guest-two"
            with self.assertRaises(PoTokenProviderRejectedRequest): provider._real_request_pot(request)
            request.visitor_data = "guest-one"
            request.is_authenticated = True
            with self.assertRaises(PoTokenProviderRejectedRequest): provider._real_request_pot(request)
        finally: proof.active_request.reset(scope)


if __name__ == "__main__": unittest.main()
