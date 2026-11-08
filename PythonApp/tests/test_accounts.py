"""Offline account-scoped production extraction and transport boundaries."""
import json
import unittest
from unittest.mock import patch
from contextlib import contextmanager

from test_session_probe import request, FakeYoutubeDL
import illucet_accounts as accounts
import illucet_ytdlp_extractor as extractor
import illucet_bridge


class AccountTests(unittest.TestCase):
    def setUp(self):
        FakeYoutubeDL.instances = []
        FakeYoutubeDL.failure = None
        FakeYoutubeDL.expire = False
        FakeYoutubeDL.mismatch = False
        self.verification = patch.object(accounts, "verify_server_session")
        self.verification.start()
        self.addCleanup(self.verification.stop)

    def test_server_must_confirm_login_not_just_cookie_presence(self):
        self.verification.stop()
        class Server:
            def _download_webpage(self, url, video_id, **kwargs):
                self.url = url
                return "fixture"
            def extract_ytcfg(self, video_id, webpage):
                return self.config
        server = Server()
        for config in ({}, {"LOGGED_IN": False}, {"LOGGED_IN": 1}):
            server.config = config
            with self.assertRaises(extractor.SafeExtractionFailure):
                accounts.verify_server_session(server)
        server.config = {"LOGGED_IN": True}
        accounts.verify_server_session(server)
        self.assertEqual(server.url, "https://www.youtube.com/")

    def test_production_jar_isolated_and_cleared_on_failure(self):
        value = {"account_cookies": request()["cookies"]}
        with self.assertRaisesRegex(RuntimeError, "fixture"):
            with accounts.downloader(value, FakeYoutubeDL, extractor._options(extractor._SafeLogger())) as ydl:
                self.assertTrue(ydl.get_info_extractor("Youtube").is_authenticated)
                self.assertIsNone(ydl.params["age_limit"])
                raise RuntimeError("fixture")
        self.assertEqual(len(FakeYoutubeDL.instances[0].cookiejar), 0)
        with accounts.downloader({}, FakeYoutubeDL, extractor._options(extractor._SafeLogger())) as ydl:
            self.assertFalse(ydl.get_info_extractor("Youtube").is_authenticated)

    def test_invalid_account_cannot_fall_back_to_guest(self):
        for cookies in (None, [], request()["cookies"][:1]):
            with self.assertRaises(extractor.SafeExtractionFailure):
                with accounts.downloader({"account_cookies": cookies}, FakeYoutubeDL,
                                         extractor._options(extractor._SafeLogger())):
                    self.fail("Invalid session reached extraction")

    def test_rotation_during_extraction_fails_and_cleans(self):
        with self.assertRaises(extractor.SafeExtractionFailure):
            with accounts.downloader({"account_cookies": request()["cookies"]}, FakeYoutubeDL,
                                     extractor._options(extractor._SafeLogger())) as ydl:
                ydl.cookiejar.clear()
        self.assertEqual(len(ydl.cookiejar), 0)

    def test_every_production_action_reaches_request_scoped_boundary(self):
        cases = [(extractor.extract_metadata, {}),
                 (extractor.extract_playlist, {"url": "https://www.youtube.com/playlist?list=PLfixture123", "maximum_entries": 25}),
                 (extractor.resolve_streams, {"format_ids": ["18"]}),
                 (extractor.resolve_dash_fragment_plan, {"format_id": "18"}),
                 (extractor.resolve_hls_playlist_plan, {"format_id": "18"})]
        for action, extra in cases:
            value = dict(request(), account_cookies=request()["cookies"], **extra)
            @contextmanager
            def boundary(received, factory, options):
                self.assertIs(received, value)
                self.assertEqual(received["account_cookies"], request()["cookies"])
                raise RuntimeError("boundary reached")
                yield
            with self.subTest(action=action.__name__), patch.object(accounts, "downloader", boundary):
                with self.assertRaisesRegex(RuntimeError, "boundary reached"):
                    action(value)

    def test_media_credentials_are_rejected_not_forwarded(self):
        for value in ({"cookies": "secret"}, {"http_headers": {"Authorization": "secret"}},
                      {"http_headers": {"Cookie": "secret"}}):
            with self.assertRaises(extractor.SafeExtractionFailure) as caught:
                accounts.validate_media_transport(value)
            self.assertNotIn("secret", str(caught.exception))
        accounts.validate_media_transport({"http_headers": {"User-Agent": "fixture"}})

    def test_authenticated_direct_resolution_rejects_required_credentials(self):
        from test_ytdlp_extractor import _FakeStreamYoutubeDL
        @contextmanager
        def boundary(request, factory, options):
            yield _FakeStreamYoutubeDL(options)
        value = {"action": "resolve_streams", "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                 "format_ids": ["251"], "account_cookies": request()["cookies"]}
        with patch.object(accounts, "downloader", boundary):
            result = illucet_bridge.handle_request(json.dumps(value))
        self.assertFalse(json.loads(result)["ok"])
        self.assertNotIn("header-secret", result)
        self.assertIn("authenticated_transport_unsupported", result)


if __name__ == "__main__":
    unittest.main()
