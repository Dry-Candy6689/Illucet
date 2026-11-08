"""Offline tests: session isolation, bounded input, safe output and cleanup."""
import copy
import json
import sys
import time
import types
import unittest
from unittest.mock import patch

native = types.ModuleType("_illucet_native")
native.is_cancelled = lambda: False
import illucet_dependency_versions as pinned_versions
native.quickjs_version = lambda: pinned_versions.QUICKJS_VERSION
native.quickjs_evaluate = lambda *args: '{"type":"result","responses":[]}'
native.emit_json = lambda value: None
sys.modules.setdefault("_illucet_native", native)

from yt_dlp import YoutubeDL
import illucet_bridge
import illucet_session_probe as probe


def request():
    return {"action": "probe_youtube_session", "download": False,
            "url": "https://www.youtube.com/watch?v=YE7VzlLtp-4",
            "cookies": [{"domain": ".youtube.com", "path": "/", "name": name,
                         "value": "synthetic-secret", "secure": True, "expires": None}
                        for name in ("LOGIN_INFO", "SAPISID")]}


class FakeYoutubeDL(YoutubeDL):
    instances = []
    failure = None
    mismatch = False
    expire = False

    def __init__(self, options):
        super().__init__(options)
        self.initial_cookie_count = len(self.cookiejar)
        self.extracted = False
        type(self).instances.append(self)

    def extract_info(self, url, *, download):
        assert url == request()["url"] and download is False
        assert self.get_info_extractor("Youtube").is_authenticated
        self.extracted = True
        if self.failure:
            raise self.failure
        if self.expire:
            self.cookiejar.clear()
        return {"id": "aaaaaaaaaaa" if self.mismatch else "YE7VzlLtp-4",
                "title": "Fixture", "is_live": False, "live_status": "not_live",
                "formats": [{"format_id": "18", "ext": "mp4", "protocol": "https",
                             "vcodec": "avc1", "acodec": "mp4a", "width": 640,
                             "height": 360, "url": "https://media.invalid/?token=secret"}]}


class SessionProbeTests(unittest.TestCase):
    def setUp(self):
        FakeYoutubeDL.instances = []
        FakeYoutubeDL.failure = None
        FakeYoutubeDL.mismatch = False
        FakeYoutubeDL.expire = False

    def test_real_cookie_recognition_and_safe_result(self):
        result = probe.probe(request(), ydl_factory=FakeYoutubeDL)
        self.assertEqual(result, {"sessionRecognized": True, "metadataExtracted": True, "formatCount": 1})
        self.assertNotIn("secret", json.dumps(result))
        ydl = FakeYoutubeDL.instances[0]
        self.assertEqual(len(ydl.cookiejar), 0)
        self.assertFalse(ydl.params["cachedir"])
        self.assertNotIn("cookiefile", ydl.params)
        self.assertNotIn("cookiesfrombrowser", ydl.params)
        self.assertTrue(ydl.params["skip_download"])

    def test_each_request_has_fresh_cookie_jar(self):
        for _ in range(2):
            probe.probe(request(), ydl_factory=FakeYoutubeDL)
        self.assertEqual([ydl.initial_cookie_count for ydl in FakeYoutubeDL.instances], [0, 0])
        self.assertIsNot(FakeYoutubeDL.instances[0].cookiejar, FakeYoutubeDL.instances[1].cookiejar)

    def test_failure_cleans_cookie_jar(self):
        FakeYoutubeDL.failure = RuntimeError("sensitive-secret")
        with self.assertRaises(RuntimeError):
            probe.probe(request(), ydl_factory=FakeYoutubeDL)
        self.assertEqual(len(FakeYoutubeDL.instances[0].cookiejar), 0)

    def test_bridge_redacts_failure_and_emits_no_events(self):
        with patch.object(probe, "probe", side_effect=RuntimeError("cookie=synthetic-secret")), \
             patch.object(illucet_bridge._illucet_native, "emit_json") as emit:
            result = illucet_bridge.handle_request(json.dumps(request()))
        self.assertFalse(json.loads(result)["ok"])
        self.assertNotIn("synthetic-secret", result)
        emit.assert_not_called()

    def test_missing_login_prevents_extraction(self):
        value = request()
        value["cookies"] = value["cookies"][:1]
        with self.assertRaises(probe.extractor.SafeExtractionFailure):
            probe.probe(value, ydl_factory=FakeYoutubeDL)
        self.assertFalse(FakeYoutubeDL.instances[0].extracted)
        self.assertEqual(len(FakeYoutubeDL.instances[0].cookiejar), 0)

    def test_identity_mismatch_and_expired_login_fail(self):
        for flag in ("mismatch", "expire"):
            with self.subTest(flag=flag):
                self.setUp()
                setattr(FakeYoutubeDL, flag, True)
                with self.assertRaises(probe.extractor.SafeExtractionFailure):
                    probe.probe(request(), ydl_factory=FakeYoutubeDL)
                self.assertEqual(len(FakeYoutubeDL.instances[0].cookiejar), 0)

    def test_invalid_cookies_rejected_before_downloader(self):
        variants = [{"domain": ".google.com"}, {"domain": "youtube.com.evil.invalid"},
                    {"path": "/account"}, {"name": "bad\nname"}, {"value": "bad;value"},
                    {"value": "x" * 16385}, {"secure": 1}, {"expires": True},
                    {"expires": int(time.time()) - 10}, {"expires": 253402300800},
                    {"unexpected": "field"}]
        for variant in variants:
            with self.subTest(variant=list(variant)):
                value = request()
                value["cookies"][0].update(variant)
                with self.assertRaises(probe.extractor.SafeExtractionFailure):
                    probe.probe(value, ydl_factory=FakeYoutubeDL)
        self.assertEqual(FakeYoutubeDL.instances, [])

    def test_duplicates_count_download_and_url_bounds(self):
        base = request()
        variants = [{"cookies": []}, {"cookies": base["cookies"] * 65},
                    {"cookies": [base["cookies"][0]] * 2}, {"download": True},
                    {"url": "file:///private/input"}]
        for variant in variants:
            value = copy.deepcopy(base)
            value.update(variant)
            with self.assertRaises(probe.extractor.SafeExtractionFailure):
                probe.probe(value, ydl_factory=FakeYoutubeDL)
        self.assertEqual(FakeYoutubeDL.instances, [])


if __name__ == "__main__":
    unittest.main()
