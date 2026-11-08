"""Deterministic tests for Illucet's yt-dlp metadata boundary."""

from __future__ import annotations

import json
import sys
import types
import unittest

native = types.ModuleType("_illucet_native")
native.is_cancelled = lambda: False
import illucet_dependency_versions as pinned_versions
native.quickjs_version = lambda: pinned_versions.QUICKJS_VERSION
native.quickjs_evaluate = (
    lambda *args: '{"type":"result","responses":[]}'
)
native.emit_json = lambda value: None
sys.modules.setdefault("_illucet_native", native)

import illucet_ytdlp_extractor as extractor
import illucet_ytdlp_provider as provider
import illucet_bridge


class _FakeYoutubeDL:
    last_options: dict[str, object] | None = None

    def __init__(self, options: dict[str, object]) -> None:
        type(self).last_options = options

    def __enter__(self):
        return self

    def __exit__(self, *args: object) -> None:
        del args

    def extract_info(
        self,
        url: str,
        *,
        download: bool,
    ) -> dict[str, object]:
        if url != "https://www.youtube.com/watch?v=dQw4w9WgXcQ":
            raise AssertionError(url)
        if download is not False:
            raise AssertionError("Metadata action enabled a download")
        diagnostics = provider._active_extraction_diagnostics.get()
        assert diagnostics is not None
        diagnostics.update(
            {
                "provider_constructed_count": 1,
                "provider_available_count": 1,
                "provider_available": True,
                "bulk_solve_call_count": 1,
                "challenge_provider_used": True,
                "challenge_request_count": 2,
                "challenge_response_count": 2,
                "challenge_types": {"n", "sig"},
                "challenge_request_counts": {"n": 1, "sig": 1},
                "challenge_response_counts": {"n": 1, "sig": 1},
                "runtime_call_count": 1,
                "ejs_core_sha3_512": "a" * 128,
                "ejs_library_sha3_512": "b" * 128,
            }
        )
        return {
            "id": "dQw4w9WgXcQ",
            "title": "Fixture title",
            "channel": "Fixture channel",
            "uploader": "Fixture uploader",
            "duration": 212.5,
            "upload_date": "20091025",
            "description": "safe text token=must-not-leak",
            "is_live": False,
            "live_status": "not_live",
            "thumbnails": [
                {
                    "url": (
                        "https://i.ytimg.com/vi/dQw4w9WgXcQ/"
                        "maxresdefault.jpg?sqp=secret"
                    ),
                    "width": 1_280,
                    "height": 720,
                    "id": "maxres",
                }
            ],
            "chapters": [
                {
                    "title": "Intro",
                    "start_time": 0,
                    "end_time": 10,
                }
            ],
            "subtitles": {
                "en": [
                    {
                        "url": (
                            "https://captions.example.invalid/manual/en.vtt?"
                            "lang=en&format=vtt"
                        ),
                        "ext": "vtt",
                        "name": "English",
                    }
                ]
            },
            "automatic_captions": {
                "es": [
                    {
                        "url": (
                            "https://captions.example.invalid/automatic/"
                            "es.vtt?lang=es&format=vtt"
                        ),
                        "ext": "vtt",
                        "name": "Spanish (automatic)",
                    }
                ]
            },
            "formats": [
                {
                    "format_id": "18",
                    "url": (
                        "https://signed.invalid/video?"
                        "sig=must-not-leak&n=must-not-leak"
                    ),
                    "manifest_url": (
                        "https://signed.invalid/manifest?"
                        "token=must-not-leak"
                    ),
                    "http_headers": {
                        "Authorization": "Bearer must-not-leak"
                    },
                    "cookies": "COOKIE=must-not-leak",
                    "ext": "mp4",
                    "container": "mp4",
                    "vcodec": "avc1.42001E",
                    "acodec": "mp4a.40.2",
                    "width": 640,
                    "height": 360,
                    "fps": 30,
                    "dynamic_range": "SDR",
                    "abr": 96.0,
                    "vbr": 500.0,
                    "tbr": 596.0,
                    "filesize_approx": 123_456,
                    "protocol": "https",
                },
                {
                    "format_id": "sb0",
                    "url": "https://signed.invalid/storyboard",
                    "vcodec": "none",
                    "acodec": "none",
                    "protocol": "mhtml",
                },
                {
                    "format_id": "drm",
                    "url": "https://signed.invalid/drm",
                    "vcodec": "vp9",
                    "acodec": "none",
                    "has_drm": True,
                    "protocol": "https",
                },
            ],
        }


class _FakePlaylistYoutubeDL:
    last_options: dict[str, object] | None = None
    last_url: str | None = None

    def __init__(self, options: dict[str, object]) -> None:
        type(self).last_options = options

    def __enter__(self):
        return self

    def __exit__(self, *args: object) -> None:
        del args

    def extract_info(
        self,
        url: str,
        *,
        download: bool,
    ) -> dict[str, object]:
        type(self).last_url = url
        if download is not False:
            raise AssertionError("Playlist action enabled a download")
        return {
            "_type": "playlist",
            "id": "PLFixture_123",
            "title": "Fixture playlist token=must-not-leak",
            "channel": "Fixture creator",
            "playlist_count": 4,
            "thumbnail": (
                "https://i.ytimg.com/vi/AbCdEf123_-/"
                "hqdefault.jpg?signature=must-not-leak"
            ),
            "webpage_url": (
                "https://www.youtube.com/playlist?"
                "list=PLFixture_123&token=must-not-leak"
            ),
            "entries": [
                {
                    "id": "AbCdEf123_-",
                    "title": "First",
                    "channel": "Fixture creator",
                    "duration": 12.5,
                    "playlist_index": 1,
                    "url": "https://www.youtube.com/shorts/AbCdEf123_-",
                    "thumbnail": (
                        "https://i.ytimg.com/vi/AbCdEf123_-/"
                        "hqdefault.jpg?sig=must-not-leak"
                    ),
                    "filesize_approx": 1_000,
                    "formats": [
                        {
                            "url": (
                                "https://signed.invalid/media?"
                                "token=must-not-leak"
                            )
                        }
                    ],
                },
                {
                    "id": "ZyXwVu987_-",
                    "title": "[Private video]",
                    "availability": "needs_auth",
                    "playlist_index": 2,
                    "url": "https://signed.invalid/private?sig=secret",
                },
                None,
                {
                    "id": "MnOpQr456_-",
                    "title": "Fourth",
                    "duration": 20,
                    "playlist_index": 4,
                    "url": "https://www.youtube.com/shorts/MnOpQr456_-",
                    "filesize": 3_000,
                },
            ],
        }


class _FakeStreamYoutubeDL:
    downloader_options: object = {
        "http_chunk_size": 10 * 1024 * 1024,
    }

    def __init__(self, options: dict[str, object]) -> None:
        del options

    def __enter__(self):
        return self

    def __exit__(self, *args: object) -> None:
        del args

    def extract_info(
        self,
        url: str,
        *,
        download: bool,
    ) -> dict[str, object]:
        if url != "https://www.youtube.com/watch?v=dQw4w9WgXcQ":
            raise AssertionError(url)
        if download is not False:
            raise AssertionError("Stream resolution enabled a download")
        return {
            "id": "dQw4w9WgXcQ",
            "formats": [
                {
                    "format_id": "251",
                    "url": (
                        "https://rr1---sn-fixture.googlevideo.com/"
                        "videoplayback?sig=transport-secret"
                    ),
                    "http_headers": {
                        "User-Agent": "Illucet fixture",
                        "Authorization": "Bearer header-secret",
                    },
                    "ext": "webm",
                    "vcodec": "none",
                    "acodec": "opus",
                    "filesize": 12_345,
                    "protocol": "https",
                    "downloader_options": self.downloader_options,
                }
            ],
        }


def _dash_info(
    *,
    fragments: object | None = None,
) -> dict[str, object]:
    return {
        "id": "dQw4w9WgXcQ",
        "is_live": False,
        "live_status": "not_live",
        "formats": [
            {
                "format_id": "137-dashy",
                "url": (
                    "https://rr1---sn-fixture.googlevideo.com/"
                    "videoplayback?sig=manifest-secret"
                ),
                "fragment_base_url": (
                    "https://rr1---sn-fixture.googlevideo.com/dash/"
                ),
                "fragments": fragments
                if fragments is not None
                else [
                    {
                        "url": (
                            "https://rr1---sn-fixture.googlevideo.com/"
                            "videoplayback?range=0-9&sig=first"
                        ),
                        "filesize": 10,
                    },
                    {
                        "path": "segment-2.m4s?sig=second",
                        "filesize": 20,
                    },
                    {
                        "url": (
                            "https://rr1---sn-fixture.googlevideo.com/"
                            "videoplayback?range=0-9&sig=first"
                        ),
                        "filesize": 10,
                    },
                ],
                "http_headers": {"User-Agent": "Illucet DASH fixture"},
                "ext": "mp4",
                "vcodec": "avc1.640028",
                "acodec": "none",
                "protocol": "http_dash_segments",
                "has_drm": False,
                "filesize": 40,
                "filesize_approx": 4_000,
            }
        ],
    }


class _FakeDASHYoutubeDL:
    info: dict[str, object] = _dash_info()

    def __init__(self, options: dict[str, object]) -> None:
        del options

    def __enter__(self):
        return self

    def __exit__(self, *args: object) -> None:
        del args

    def extract_info(
        self,
        url: str,
        *,
        download: bool,
    ) -> dict[str, object]:
        if url != "https://www.youtube.com/watch?v=dQw4w9WgXcQ":
            raise AssertionError(url)
        if download is not False:
            raise AssertionError("DASH resolution enabled a download")
        return self.info


def _hls_info() -> dict[str, object]:
    return {
        "id": "dQw4w9WgXcQ",
        "is_live": False,
        "live_status": "not_live",
        "formats": [
            {
                "format_id": "hls-720",
                "url": (
                    "https://manifest.googlevideo.com/api/manifest/"
                    "hls_variant/playlist/index.m3u8?sig=media-secret"
                ),
                "manifest_url": (
                    "https://manifest.googlevideo.com/api/manifest/"
                    "hls_playlist/master.m3u8?sig=master-secret"
                ),
                "http_headers": {
                    "User-Agent": "Illucet HLS fixture",
                    "Accept-Language": "en-US",
                },
                "ext": "mp4",
                "vcodec": "avc1.64001f",
                "acodec": "mp4a.40.2",
                "protocol": "m3u8_native",
                "has_drm": False,
            }
        ],
    }


class _FakeHLSYoutubeDL:
    info: dict[str, object] = _hls_info()

    def __init__(self, options: dict[str, object]) -> None:
        del options

    def __enter__(self):
        return self

    def __exit__(self, *args: object) -> None:
        del args

    def extract_info(
        self,
        url: str,
        *,
        download: bool,
    ) -> dict[str, object]:
        if url != "https://www.youtube.com/watch?v=dQw4w9WgXcQ":
            raise AssertionError(url)
        if download is not False:
            raise AssertionError("HLS resolution enabled a download")
        return self.info


class YTDLPExtractorTests(unittest.TestCase):
    def test_preference_rank_preserves_order_without_transport_secrets(self):
        raw = [
            {"format_id": "aac", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 256,
             "url": "https://example.invalid/media?token=secret", "http_headers": {"Cookie": "secret"}},
            {"format_id": "drm", "has_drm": True},
            {"format_id": "opus", "ext": "webm", "vcodec": "none", "acodec": "opus", "abr": 160,
             "url": "https://example.invalid/opus?token=secret"},
        ]
        formats = extractor._sanitize_formats(raw)
        self.assertEqual([item["format_id"] for item in formats], ["aac", "opus"])
        self.assertEqual([item["extractor_preference_rank"] for item in formats], [0, 2])
        self.assertNotIn("secret", json.dumps(formats))
        self.assertTrue(all("url" not in item and "http_headers" not in item for item in formats))

    def test_completed_replays_preserve_exact_vod_fragment_plans(self) -> None:
        for make_info, factory, resolve, format_id in (
            (_dash_info, _FakeDASHYoutubeDL, extractor.resolve_dash_fragment_plan, "137-dashy"),
            (_hls_info, _FakeHLSYoutubeDL, extractor.resolve_hls_playlist_plan, "hls-720"),
        ):
            with self.subTest(format_id=format_id):
                request = {"url": "https://youtu.be/dQw4w9WgXcQ", "format_id": format_id}
                factory.info = make_info()
                vod = resolve(request, ydl_factory=factory)
                replay = make_info()
                replay["live_status"] = "was_live"
                replay["was_live"] = True
                factory.info = replay
                self.assertEqual(resolve(request, ydl_factory=factory), vod)

    def test_replay_admission_rejects_unfinished_and_malformed_sources(self) -> None:
        for make_info, factory, resolve, format_id, code in (
            (_dash_info, _FakeDASHYoutubeDL, extractor.resolve_dash_fragment_plan,
             "137-dashy", "unsupported_live_fragment_plan"),
            (_hls_info, _FakeHLSYoutubeDL, extractor.resolve_hls_playlist_plan,
             "hls-720", "unsupported_live_hls_playlist"),
        ):
            cases = [
                {"live_status": status} for status in
                ("is_live", "is_upcoming", "post_live", "unknown", "", " " * 65,
                 [], {}, False, 1)
            ] + [
                {"live_status": "was_live", "is_live": value}
                for value in (True, 0, 1, "false", [], {})
            ]
            for updates in cases:
                with self.subTest(format_id=format_id, updates=updates):
                    info = make_info()
                    info.update(updates)
                    factory.info = info
                    with self.assertRaises(extractor.SafeExtractionFailure) as error:
                        resolve({"url": "https://youtu.be/dQw4w9WgXcQ", "format_id": format_id},
                                ydl_factory=factory)
                    self.assertEqual(error.exception.code, code)

            # A processed-replay label does not authorize a live-from-start format.
            info = make_info()
            info["live_status"] = "was_live"
            info["formats"][0]["is_from_start"] = True
            factory.info = info
            with self.assertRaises(extractor.SafeExtractionFailure) as error:
                resolve({"url": "https://youtu.be/dQw4w9WgXcQ", "format_id": format_id},
                        ydl_factory=factory)
            self.assertEqual(error.exception.code, code)

    def test_pinned_provider_contract_and_ejs_challenge_seam(self) -> None:
        provider._assert_runtime_contract()
        smoke = provider.run_initialized_provider_smoke()
        fail_closed = provider.run_fail_closed_director_smoke()

        self.assertTrue(smoke["provider_registered"])
        self.assertTrue(smoke["available"])
        self.assertEqual(smoke["provider_key"], "IllucetQuickJS")
        self.assertEqual(smoke["yt_dlp_version"], provider.EXPECTED_YTDLP_VERSION)
        self.assertEqual(smoke["ejs_version"], "0.8.0")
        self.assertEqual(
            smoke["core_hash"],
            "ee5b307d07f55e91e4723edf5ac205cc877a474187849d757dc1322e38427b1"
            "57a9d706d510c1723d3670f98e5a3f8cbcde77874a80406bd7204bc9fea30f283",
        )
        self.assertEqual(
            smoke["library_hash"],
            "8420c259ad16e99ce004e4651ac1bcabb53b4457bf5668a97a9359be9a998a7"
            "89fee8ab124ee17f91a2ea8fd84e0f2b2fc8eabcaf0b16a186ba734cf422ad053",
        )
        self.assertEqual(
            json.loads(str(smoke["output"])),
            {"type": "result", "responses": []},
        )
        self.assertTrue(fail_closed["all_cases_passed"])
        self.assertFalse(fail_closed["sensitive_log_found"])

    def test_metadata_action_is_strict_and_secret_free(self) -> None:
        result = extractor.extract_metadata(
            {
                "action": "extract_metadata",
                "url": (
                    " https://youtu.be/dQw4w9WgXcQ?"
                    "si=tracking-value "
                ),
                "download": False,
            },
            ydl_factory=_FakeYoutubeDL,
        )

        metadata = result["metadata"]
        self.assertEqual(
            metadata["canonical_url"],
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        )
        self.assertEqual(metadata["upload_date"], "2009-10-25")
        self.assertEqual(metadata["duration_seconds"], 212.5)
        self.assertEqual(len(metadata["formats"]), 1)
        self.assertEqual(metadata["formats"][0]["format_id"], "18")
        self.assertEqual(
            metadata["formats"][0]["source_type"],
            "direct_http",
        )
        self.assertEqual(len(metadata["subtitles"]), 2)
        manual, automatic = metadata["subtitles"]
        self.assertEqual(manual["language"], "en")
        self.assertEqual(manual["name"], "English")
        self.assertIs(manual["automatic"], False)
        self.assertRegex(manual["track_id"], r"^subtitle-[0-9a-f]{24}$")
        self.assertEqual(
            manual["formats"][0]["url"],
            (
                "https://captions.example.invalid/manual/en.vtt?"
                "lang=en&format=vtt"
            ),
        )
        self.assertEqual(manual["formats"][0]["extension"], "vtt")
        self.assertRegex(
            manual["formats"][0]["format_id"],
            r"^subtitle-format-[0-9a-f]{24}$",
        )
        self.assertEqual(automatic["language"], "es")
        self.assertEqual(automatic["name"], "Spanish (automatic)")
        self.assertIs(automatic["automatic"], True)
        self.assertNotEqual(manual["track_id"], automatic["track_id"])
        self.assertEqual(
            metadata["thumbnails"][0]["url"],
            (
                "https://i.ytimg.com/vi/dQw4w9WgXcQ/"
                "maxresdefault.jpg"
            ),
        )

        encoded = json.dumps(result, sort_keys=True)
        self.assertNotIn("signed.invalid", encoded)
        self.assertNotIn("must-not-leak", encoded)
        self.assertNotIn("tracking-value", encoded)
        self.assertNotIn("Authorization", encoded)
        self.assertNotIn("COOKIE=", encoded)
        media_format = metadata["formats"][0]
        for excluded_key in (
            "url",
            "manifest_url",
            "fragments",
            "http_headers",
            "cookies",
        ):
            self.assertNotIn(excluded_key, media_format)

        evidence = result["provider_evidence"]
        self.assertEqual(evidence["format_count"], 1)
        self.assertEqual(evidence["challenge_request_count"], 2)
        self.assertEqual(evidence["challenge_response_count"], 2)
        self.assertEqual(
            evidence["challenge_request_counts"],
            {"n": 1, "sig": 1},
        )
        self.assertEqual(evidence["runtime_call_count"], 1)
        self.assertEqual(evidence["runtime_error_count"], 0)
        self.assertRegex(
            evidence["format_inventory_sha256"],
            r"^[0-9a-f]{64}$",
        )

    def test_subtitle_urls_fail_closed_and_identities_are_deterministic(
        self,
    ) -> None:
        valid_one = "https://captions.example.invalid/en/one.vtt"
        valid_two = "https://captions.example.invalid/en/two.vtt"
        invalid_urls = (
            None,
            "",
            "http://captions.example.invalid/en.vtt",
            "file:///private/tmp/en.vtt",
            "data:text/vtt,fixture",
            "javascript:alert(1)",
            "https://user:password@captions.example.invalid/en.vtt",
            " https://captions.example.invalid/en.vtt",
            "https://captions.example.invalid\\@elsewhere.invalid/en.vtt",
            "https://captions.example.invalid:99999/en.vtt",
            "https:///missing-host.vtt",
            "https://captions.example.invalid/" + ("x" * 4_096),
        )
        raw_formats = [
            {"url": valid_one, "ext": "vtt", "name": "English"},
            {"url": valid_one, "ext": "vtt", "name": "duplicate"},
            {"url": valid_two, "ext": "vtt", "name": "English"},
            *(
                {"url": url, "ext": "vtt", "name": "invalid"}
                for url in invalid_urls
            ),
        ]
        source = {"en": raw_formats}

        first = extractor._subtitle_records(source, automatic=False)
        second = extractor._subtitle_records(source, automatic=False)
        automatic = extractor._subtitle_records(source, automatic=True)

        self.assertEqual(first, second)
        self.assertEqual(len(first), 1)
        self.assertEqual(len(first[0]["formats"]), 2)
        self.assertEqual(
            [item["url"] for item in first[0]["formats"]],
            [valid_one, valid_two],
        )
        format_ids = [
            item["format_id"] for item in first[0]["formats"]
        ]
        self.assertEqual(len(set(format_ids)), 2)
        self.assertNotIn("captions", first[0]["track_id"])
        self.assertNotIn("captions", "".join(format_ids))
        self.assertNotEqual(first[0]["track_id"], automatic[0]["track_id"])

    def test_subtitle_record_bounds_drop_bad_text_and_reject_huge_lists(
        self,
    ) -> None:
        self.assertEqual(
            extractor._subtitle_records(
                {"x" * 129: [{"url": "https://captions.invalid/x.vtt"}]},
                automatic=False,
            ),
            [],
        )
        records = extractor._subtitle_records(
            {
                "en": [
                    {
                        "url": "https://captions.invalid/en.vtt",
                        "ext": "x" * 33,
                        "name": "x" * 257,
                    }
                ]
            },
            automatic=False,
        )
        self.assertEqual(records, [])
        usable = extractor._subtitle_records({"en": [{
            "url": "https://captions.invalid/en.vtt", "ext": "vtt", "name": "x" * 257,
        }]}, automatic=False)
        self.assertIsNone(usable[0]["formats"][0]["name"])

        with self.assertRaises(
            extractor.SafeExtractionFailure
        ) as languages:
            extractor._subtitle_records(
                {
                    f"language-{index}": []
                    for index in range(extractor._MAX_SUBTITLE_LANGUAGES + 1)
                },
                automatic=False,
            )
        self.assertEqual(languages.exception.code, "metadata_too_large")

        with self.assertRaises(extractor.SafeExtractionFailure) as formats:
            extractor._subtitle_records(
                {
                    "en": [
                        {"url": "https://captions.invalid/en.vtt"}
                    ]
                    * (extractor._MAX_SUBTITLE_FORMATS + 1)
                },
                automatic=False,
            )
        self.assertEqual(formats.exception.code, "metadata_too_large")

    def test_crowded_subtitle_catalog_keeps_every_selectable_identity(self) -> None:
        languages, versions = 177, 19
        source = {
            f"lang-{language}": [
                {"url": f"https://captions.invalid/{language}/{version}/{ext}?padding=" + "x" * 400,
                 "ext": ext, "name": f"Translation {version}"}
                for version in range(versions)
                for ext in ["json3", "srv1", "srv2", "srv3", "ttml", "srt", "vtt"]
            ] for language in range(languages)
        }
        self.assertGreater(len(json.dumps(source).encode()), extractor._MAX_OUTPUT_BYTES)
        records = extractor._subtitle_records(source, automatic=True)
        self.assertEqual(len(records), languages)
        self.assertEqual(sum(len(track["formats"]) for track in records), languages * versions)
        self.assertLess(len(json.dumps(records).encode()), extractor._MAX_OUTPUT_BYTES)
        for track in records:
            expected_track = extractor._subtitle_identity("subtitle", "automatic", track["language"])
            self.assertEqual(track["track_id"], expected_track)
            for version, item in enumerate(track["formats"]):
                self.assertEqual(item["extension"], "vtt")
                self.assertEqual(item["format_id"], extractor._subtitle_identity(
                    "subtitle-format", expected_track, "vtt", f"Translation {version}", 0))

    def test_subtitle_filter_keeps_case_insensitive_vtt_and_manual_identities(self) -> None:
        source = {"en": [
            {"url": "https://captions.invalid/a.json", "ext": "json3", "name": "English"},
            {"url": "https://captions.invalid/a.vtt", "ext": "VTT", "name": "English"},
            {"url": "https://captions.invalid/b.vtt", "ext": "vtt", "name": "English"},
            {"url": "https://captions.invalid/b.vtt", "ext": "vtt", "name": "English"},
        ]}
        records = extractor._subtitle_records(source, automatic=False)
        self.assertEqual(len(records[0]["formats"]), 2)
        self.assertFalse(records[0]["automatic"])
        self.assertEqual(records, extractor._subtitle_records(source, automatic=False))

    def test_text_bounds_measure_utf8_bytes(self) -> None:
        self.assertEqual(extractor._bounded_text("é" * 256, maximum=512), "é" * 256)
        with self.assertRaises(extractor.SafeExtractionFailure):
            extractor._bounded_text("é" * 257, maximum=512)
        self.assertIsNone(extractor._safe_subtitle_text("é" * 129, maximum=256))

    def test_metadata_limit_includes_outer_envelope(self) -> None:
        from unittest.mock import patch
        data = {"metadata": {"title": "x" * 180}, "provider_evidence": {}}
        limit = len(json.dumps(data["metadata"], separators=(",", ":")).encode()) + 1
        with patch.object(extractor, "extract_metadata", return_value=data), patch.object(extractor, "_MAX_OUTPUT_BYTES", limit):
            response = json.loads(illucet_bridge._extract_metadata({"url": "https://youtu.be/dQw4w9WgXcQ"}))
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "metadata_too_large")

    def test_metadata_options_disable_unsafe_paths(self) -> None:
        extractor.extract_metadata(
            {
                "url": "https://youtu.be/dQw4w9WgXcQ",
                "download": False,
            },
            ydl_factory=_FakeYoutubeDL,
        )
        options = _FakeYoutubeDL.last_options
        assert options is not None
        self.assertIs(options["skip_download"], True)
        self.assertIs(options["noplaylist"], True)
        self.assertIs(options["extract_flat"], False)
        self.assertIs(options["ignore_no_formats_error"], False)
        self.assertIs(options["allow_unplayable_formats"], False)
        self.assertIs(options["check_formats"], False)
        self.assertEqual(options["age_limit"], 0)
        self.assertEqual(options["allowed_extractors"], ["youtube"])
        self.assertEqual(options["js_runtimes"], {})
        self.assertEqual(options["remote_components"], set())
        self.assertEqual(options["proxy"], "")
        self.assertIs(options["prefer_insecure"], False)
        self.assertIs(options["debug_printtraffic"], False)
        self.assertIs(options["cachedir"], False)
        self.assertIs(options["enable_file_urls"], False)
        self.assertIs(options["geo_bypass"], False)
        self.assertIs(options["nocheckcertificate"], False)
        self.assertEqual(options["socket_timeout"], 15)

    def test_valid_http_chunk_size_projects_through_typed_stream(self) -> None:
        _FakeStreamYoutubeDL.downloader_options = {
            "http_chunk_size": 10 * 1024 * 1024,
            "arbitrary_option": "must-not-cross-bridge",
            "cookies": "COOKIE=downloader-secret",
        }

        result = extractor.resolve_streams(
            {
                "url": "https://youtu.be/dQw4w9WgXcQ",
                "format_ids": ["251"],
            },
            ydl_factory=_FakeStreamYoutubeDL,
        )

        self.assertEqual(result["video_id"], "dQw4w9WgXcQ")
        self.assertEqual(len(result["streams"]), 1)
        stream = result["streams"][0]
        self.assertEqual(stream["format_id"], "251")
        self.assertEqual(stream["http_chunk_size"], 10 * 1024 * 1024)
        self.assertEqual(stream["http_headers"], {
            "User-Agent": "Illucet fixture",
        })
        encoded = json.dumps(result, sort_keys=True)
        self.assertNotIn("downloader_options", encoded)
        self.assertNotIn("arbitrary_option", encoded)
        self.assertNotIn("must-not-cross-bridge", encoded)
        self.assertNotIn("downloader-secret", encoded)
        self.assertNotIn("header-secret", encoded)

    def test_missing_http_chunk_size_remains_absent(self) -> None:
        _FakeStreamYoutubeDL.downloader_options = {
            "arbitrary_option": 1,
        }

        result = extractor.resolve_streams(
            {
                "url": "https://youtu.be/dQw4w9WgXcQ",
                "format_ids": ["251"],
            },
            ydl_factory=_FakeStreamYoutubeDL,
        )

        self.assertNotIn("http_chunk_size", result["streams"][0])

    def test_stream_availability_is_absolute_and_bounded(self) -> None:
        from unittest.mock import patch
        now = 1_800_000_000
        base = _FakeStreamYoutubeDL({}).extract_info(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ", download=False)
        for value in (0, now - 1, now + 4, now + 4.25, None):
            with self.subTest(value=value):
                info = json.loads(json.dumps(base))
                info["formats"][0]["available_at"] = value
                with patch.object(extractor.time, "time", return_value=now), \
                     patch.object(_FakeStreamYoutubeDL, "extract_info", return_value=info):
                    result = extractor.resolve_streams(
                        {"url": "https://youtu.be/dQw4w9WgXcQ", "format_ids": ["251"]},
                        ydl_factory=_FakeStreamYoutubeDL)
                self.assertEqual(result["streams"][0].get("available_at"), value)
        for value in (True, "1800000004", -1, now + 601, float("nan"),
                      float("inf"), 10 ** 1000, {}, []):
            with self.subTest(invalid_type=type(value).__name__):
                info = json.loads(json.dumps(base))
                info["formats"][0]["available_at"] = value
                with patch.object(extractor.time, "time", return_value=now), \
                     patch.object(_FakeStreamYoutubeDL, "extract_info", return_value=info):
                    with self.assertRaises(extractor.SafeExtractionFailure) as caught:
                        extractor.resolve_streams(
                            {"url": "https://youtu.be/dQw4w9WgXcQ", "format_ids": ["251"]},
                            ydl_factory=_FakeStreamYoutubeDL)
                self.assertEqual(caught.exception.code, "invalid_stream_availability")

    def test_fragment_and_playlist_plans_keep_the_availability_deadline(self) -> None:
        from unittest.mock import patch
        deadline = 1_800_000_004
        for factory, info, action, format_id in (
            (_FakeDASHYoutubeDL, _dash_info(), extractor.resolve_dash_fragment_plan, "137-dashy"),
            (_FakeHLSYoutubeDL, _hls_info(), extractor.resolve_hls_playlist_plan, "hls-720"),
        ):
            with self.subTest(format_id=format_id):
                info["formats"][0]["available_at"] = deadline
                with patch.object(extractor.time, "time", return_value=deadline - 4), \
                     patch.object(factory, "info", info):
                    result = action({"url": "https://youtu.be/dQw4w9WgXcQ", "format_id": format_id},
                                    ydl_factory=factory)
                self.assertEqual(result["available_at"], deadline)

    def test_invalid_http_chunk_sizes_are_dropped(self) -> None:
        invalid_values = (
            -1,
            0,
            extractor._MAX_HTTP_CHUNK_SIZE_BYTES + 1,
            True,
            10.0,
            "10485760",
            [],
            {},
            None,
        )
        for value in invalid_values:
            with self.subTest(value=value):
                _FakeStreamYoutubeDL.downloader_options = {
                    "http_chunk_size": value,
                }
                result = extractor.resolve_streams(
                    {
                        "url": "https://youtu.be/dQw4w9WgXcQ",
                        "format_ids": ["251"],
                    },
                    ydl_factory=_FakeStreamYoutubeDL,
                )
                self.assertNotIn(
                    "http_chunk_size",
                    result["streams"][0],
                )

    def test_dash_fragment_plan_preserves_exact_order_and_repeats(self) -> None:
        _FakeDASHYoutubeDL.info = _dash_info()

        result = extractor.resolve_dash_fragment_plan(
            {
                "url": "https://youtu.be/dQw4w9WgXcQ",
                "format_id": "137-dashy",
                "download": False,
            },
            ydl_factory=_FakeDASHYoutubeDL,
        )

        self.assertEqual(result["video_id"], "dQw4w9WgXcQ")
        self.assertEqual(result["format_id"], "137-dashy")
        self.assertEqual(result["protocol"], "http_dash_segments")
        self.assertEqual(result["source_type"], "dash")
        self.assertEqual(result["extension"], "mp4")
        self.assertEqual(result["expected_bytes"], 40)
        self.assertEqual(result["fragment_count"], 3)
        self.assertEqual(
            [fragment["position"] for fragment in result["fragments"]],
            [0, 1, 2],
        )
        URLs = [fragment["url"] for fragment in result["fragments"]]
        self.assertEqual(
            [fragment["expected_bytes"] for fragment in result["fragments"]],
            [10, 20, 10],
        )
        self.assertEqual(URLs[0], URLs[2])
        self.assertEqual(
            URLs[1],
            (
                "https://rr1---sn-fixture.googlevideo.com/dash/"
                "segment-2.m4s?sig=second"
            ),
        )
        self.assertEqual(
            result["http_headers"],
            {"User-Agent": "Illucet DASH fixture"},
        )

    def test_dash_integrity_metadata_ignores_approximate_and_undocumented_hashes(
        self,
    ) -> None:
        info = _dash_info()
        raw_format = info["formats"][0]
        assert isinstance(raw_format, dict)
        raw_format.pop("filesize")
        fragments = raw_format["fragments"]
        assert isinstance(fragments, list)
        first = fragments[0]
        assert isinstance(first, dict)
        first["sha256"] = "not-a-documented-yt-dlp-fragment-field"
        first.pop("filesize")
        _FakeDASHYoutubeDL.info = info

        result = extractor.resolve_dash_fragment_plan(
            {
                "url": "https://youtu.be/dQw4w9WgXcQ",
                "format_id": "137-dashy",
            },
            ydl_factory=_FakeDASHYoutubeDL,
        )

        self.assertIsNone(result["expected_bytes"])
        self.assertIsNone(result["fragments"][0]["expected_bytes"])
        self.assertEqual(
            set(result["fragments"][0]),
            {"position", "url", "expected_bytes"},
        )

    def test_dash_fragment_plan_fails_closed_for_unsafe_or_ambiguous_inputs(
        self,
    ) -> None:
        safe_url = (
            "https://rr1---sn-fixture.googlevideo.com/"
            "videoplayback?range=0-9"
        )
        cases: tuple[
            tuple[str, dict[str, object], str],
            ...,
        ] = (
            (
                "orderless",
                {"fragments": {"first": {"url": safe_url}}},
                "fragment_order_unavailable",
            ),
            (
                "empty",
                {"fragments": []},
                "empty_fragment_plan",
            ),
            (
                "unsafe scheme",
                {"fragments": [{"url": "http://example.com/fragment"}]},
                "unsupported_stream_host",
            ),
            (
                "unsafe host",
                {"fragments": [{"url": "https://example.com/fragment"}]},
                "unsupported_stream_host",
            ),
            (
                "two transport identities",
                {
                    "fragments": [
                        {"url": safe_url, "path": "fragment.m4s"}
                    ]
                },
                "ambiguous_fragment_transport",
            ),
            (
                "absolute fragment path",
                {"fragments": [{"path": "/fragment.m4s"}]},
                "ambiguous_fragment_transport",
            ),
            (
                "contradictory index",
                {"fragments": [{"url": safe_url, "index": 9}]},
                "ambiguous_fragment_order",
            ),
            (
                "secret header",
                {
                    "http_headers": {
                        "Authorization": "Bearer must-not-cross"
                    }
                },
                "invalid_fragment_headers",
            ),
            (
                "case-duplicate headers",
                {
                    "http_headers": {
                        "User-Agent": "first",
                        "user-agent": "second",
                    }
                },
                "invalid_fragment_headers",
            ),
            (
                "direct protocol",
                {"protocol": "https"},
                "unsupported_stream_protocol",
            ),
            (
                "unsupported fragment transport parameters",
                {"extra_param_to_segment_url": ["token=secret"]},
                "unsupported_fragment_transport",
            ),
            (
                "DRM",
                {"has_drm": True},
                "drm_format_unsupported",
            ),
            (
                "untyped DRM state",
                {"has_drm": "unknown"},
                "drm_format_unsupported",
            ),
            (
                "invalid exact format bytes",
                {"filesize": 40.5},
                "invalid_fragment_integrity_metadata",
            ),
            (
                "unsupported container",
                {"ext": "bin"},
                "unsupported_dash_container",
            ),
            (
                "invalid exact fragment bytes",
                {
                    "fragments": [
                        {"url": safe_url, "filesize": -1}
                    ]
                },
                "invalid_fragment_integrity_metadata",
            ),
        )

        for label, updates, expected_code in cases:
            with self.subTest(label=label):
                info = _dash_info()
                raw_format = info["formats"][0]
                assert isinstance(raw_format, dict)
                raw_format.update(updates)
                _FakeDASHYoutubeDL.info = info
                with self.assertRaises(extractor.SafeExtractionFailure) as error:
                    extractor.resolve_dash_fragment_plan(
                        {
                            "url": "https://youtu.be/dQw4w9WgXcQ",
                            "format_id": "137-dashy",
                        },
                        ydl_factory=_FakeDASHYoutubeDL,
                    )
                self.assertEqual(error.exception.code, expected_code)
                self.assertNotIn("must-not-cross", error.exception.message)

        missing_extension = _dash_info()
        missing_raw_format = missing_extension["formats"][0]
        assert isinstance(missing_raw_format, dict)
        missing_raw_format.pop("ext")
        _FakeDASHYoutubeDL.info = missing_extension
        with self.assertRaises(extractor.SafeExtractionFailure) as error:
            extractor.resolve_dash_fragment_plan(
                {
                    "url": "https://youtu.be/dQw4w9WgXcQ",
                    "format_id": "137-dashy",
                },
                ydl_factory=_FakeDASHYoutubeDL,
            )
        self.assertEqual(error.exception.code, "unsupported_dash_container")

    def test_dash_fragment_plan_rejects_live_duplicate_and_unbounded_plans(
        self,
    ) -> None:
        live = _dash_info()
        live["live_status"] = "is_live"
        _FakeDASHYoutubeDL.info = live
        with self.assertRaises(extractor.SafeExtractionFailure) as error:
            extractor.resolve_dash_fragment_plan(
                {
                    "url": "https://youtu.be/dQw4w9WgXcQ",
                    "format_id": "137-dashy",
                },
                ydl_factory=_FakeDASHYoutubeDL,
            )
        self.assertEqual(
            error.exception.code,
            "unsupported_live_fragment_plan",
        )

        mismatched = _dash_info()
        mismatched["id"] = "AbCdEf123_-"
        _FakeDASHYoutubeDL.info = mismatched
        with self.assertRaises(extractor.SafeExtractionFailure) as error:
            extractor.resolve_dash_fragment_plan(
                {
                    "url": "https://youtu.be/dQw4w9WgXcQ",
                    "format_id": "137-dashy",
                },
                ydl_factory=_FakeDASHYoutubeDL,
            )
        self.assertEqual(error.exception.code, "verification_mismatch")

        duplicate = _dash_info()
        duplicate_formats = duplicate["formats"]
        assert isinstance(duplicate_formats, list)
        duplicate_formats.append(dict(duplicate_formats[0]))
        _FakeDASHYoutubeDL.info = duplicate
        with self.assertRaises(extractor.SafeExtractionFailure) as error:
            extractor.resolve_dash_fragment_plan(
                {
                    "url": "https://youtu.be/dQw4w9WgXcQ",
                    "format_id": "137-dashy",
                },
                ydl_factory=_FakeDASHYoutubeDL,
            )
        self.assertEqual(error.exception.code, "ambiguous_format_selection")

        safe_fragment = {
            "url": (
                "https://rr1---sn-fixture.googlevideo.com/fragment"
            )
        }
        _FakeDASHYoutubeDL.info = _dash_info(
            fragments=[
                dict(safe_fragment)
                for _ in range(extractor._MAX_DASH_FRAGMENTS + 1)
            ]
        )
        with self.assertRaises(extractor.SafeExtractionFailure) as error:
            extractor.resolve_dash_fragment_plan(
                {
                    "url": "https://youtu.be/dQw4w9WgXcQ",
                    "format_id": "137-dashy",
                },
                ydl_factory=_FakeDASHYoutubeDL,
            )
        self.assertEqual(error.exception.code, "fragment_plan_too_large")

        for container in (None, [], "http_chunk_size=10485760"):
            with self.subTest(container=container):
                _FakeStreamYoutubeDL.downloader_options = container
                result = extractor.resolve_streams(
                    {
                        "url": "https://youtu.be/dQw4w9WgXcQ",
                        "format_ids": ["251"],
                    },
                    ydl_factory=_FakeStreamYoutubeDL,
                )
                self.assertNotIn(
                    "http_chunk_size",
                    result["streams"][0],
                )

    def test_real_upstream_default_headers_cross_fragment_boundaries(self) -> None:
        from yt_dlp.utils.networking import std_headers
        for project in (extractor._resolved_hls_headers, extractor._resolved_fragment_headers):
            with self.subTest(project=project.__name__):
                projected = project(std_headers)
                self.assertEqual(projected["Sec-Fetch-Mode"], "navigate")
                self.assertEqual(set(projected), set(std_headers))
                for unsafe in ({"Sec-Fetch-Mode": "secret"},
                               {"Sec-Fetch-Mode": "navigate\r\nCookie: secret"},
                               {"Sec-Fetch-Mode": "navigate", "Cookie": "secret"}):
                    with self.assertRaises(extractor.SafeExtractionFailure):
                        project(unsafe)

    def test_hls_playlist_plan_preserves_exact_pinned_identity(self) -> None:
        _FakeHLSYoutubeDL.info = _hls_info()

        result = extractor.resolve_hls_playlist_plan(
            {
                "url": "https://youtu.be/dQw4w9WgXcQ",
                "format_id": "hls-720",
                "download": False,
            },
            ydl_factory=_FakeHLSYoutubeDL,
        )

        self.assertEqual(result["video_id"], "dQw4w9WgXcQ")
        self.assertEqual(result["format_id"], "hls-720")
        self.assertEqual(result["protocol"], "m3u8_native")
        self.assertEqual(result["source_type"], "hls")
        self.assertEqual(result["extension"], "mp4")
        self.assertIs(result["has_video"], True)
        self.assertIs(result["has_audio"], True)
        self.assertEqual(
            result["http_headers"],
            {
                "User-Agent": "Illucet HLS fixture",
                "Accept-Language": "en-US",
            },
        )
        self.assertIn("hls_playlist", result["manifest_url"])
        self.assertIn("hls_variant", result["media_playlist_url"])
        self.assertEqual(
            set(result),
            {
                "video_id",
                "format_id",
                "protocol",
                "source_type",
                "extension",
                "has_video",
                "has_audio",
                "http_headers",
                "manifest_url",
                "media_playlist_url",
            },
        )

        direct_media = _hls_info()
        raw_format = direct_media["formats"][0]
        assert isinstance(raw_format, dict)
        raw_format.pop("manifest_url")
        _FakeHLSYoutubeDL.info = direct_media
        direct_result = extractor.resolve_hls_playlist_plan(
            {
                "url": "https://youtu.be/dQw4w9WgXcQ",
                "format_id": "hls-720",
            },
            ydl_factory=_FakeHLSYoutubeDL,
        )
        self.assertEqual(
            direct_result["manifest_url"],
            direct_result["media_playlist_url"],
        )

    def test_hls_playlist_plan_fails_closed_for_unsupported_identity(self) -> None:
        cases: tuple[tuple[str, dict[str, object], str], ...] = (
            ("DRM", {"has_drm": "maybe"}, "drm_format_unsupported"),
            ("missing extension", {"ext": None}, "unsupported_hls_container"),
            ("unsupported extension", {"ext": "ts"}, "unsupported_hls_container"),
            ("direct protocol", {"protocol": "https"}, "unsupported_stream_protocol"),
            (
                "secret header",
                {"http_headers": {"Authorization": "Bearer must-not-cross"}},
                "invalid_hls_headers",
            ),
            (
                "case duplicate headers",
                {"http_headers": {"User-Agent": "one", "user-agent": "two"}},
                "invalid_hls_headers",
            ),
            (
                "unsafe media host",
                {"url": "https://example.invalid/media.m3u8?sig=secret"},
                "unsupported_stream_host",
            ),
            (
                "unsafe master port",
                {
                    "manifest_url": (
                        "https://manifest.googlevideo.com:8443/master.m3u8"
                    )
                },
                "unsupported_stream_host",
            ),
            (
                "credentials",
                {
                    "manifest_url": (
                        "https://user:password@manifest.googlevideo.com/"
                        "master.m3u8"
                    )
                },
                "unsupported_stream_host",
            ),
            ("AES", {"hls_aes": {}}, "unsupported_hls_transport"),
            (
                "segment query mutation",
                {"extra_param_to_segment_url": "token=secret"},
                "unsupported_hls_transport",
            ),
            ("cookies", {"cookies": "session=secret"}, "unsupported_hls_transport"),
        )

        for label, updates, expected_code in cases:
            with self.subTest(label=label):
                info = _hls_info()
                raw_format = info["formats"][0]
                assert isinstance(raw_format, dict)
                raw_format.update(updates)
                _FakeHLSYoutubeDL.info = info
                with self.assertRaises(extractor.SafeExtractionFailure) as error:
                    extractor.resolve_hls_playlist_plan(
                        {
                            "url": "https://youtu.be/dQw4w9WgXcQ",
                            "format_id": "hls-720",
                        },
                        ydl_factory=_FakeHLSYoutubeDL,
                    )
                self.assertEqual(error.exception.code, expected_code)
                self.assertNotIn("must-not-cross", error.exception.message)
                self.assertNotIn("session=secret", error.exception.message)

        duplicate = _hls_info()
        formats = duplicate["formats"]
        assert isinstance(formats, list)
        formats.append(dict(formats[0]))
        _FakeHLSYoutubeDL.info = duplicate
        with self.assertRaises(extractor.SafeExtractionFailure) as error:
            extractor.resolve_hls_playlist_plan(
                {
                    "url": "https://youtu.be/dQw4w9WgXcQ",
                    "format_id": "hls-720",
                },
                ydl_factory=_FakeHLSYoutubeDL,
            )
        self.assertEqual(error.exception.code, "ambiguous_format_selection")

        live = _hls_info()
        live["live_status"] = "is_live"
        _FakeHLSYoutubeDL.info = live
        with self.assertRaises(extractor.SafeExtractionFailure) as error:
            extractor.resolve_hls_playlist_plan(
                {
                    "url": "https://youtu.be/dQw4w9WgXcQ",
                    "format_id": "hls-720",
                },
                ydl_factory=_FakeHLSYoutubeDL,
            )
        self.assertEqual(error.exception.code, "unsupported_live_hls_playlist")

    def test_hls_bridge_action_returns_only_a_bounded_typed_error(self) -> None:
        response = json.loads(
            illucet_bridge.handle_request(
                json.dumps(
                    {
                        "action": "resolve_hls_playlist_plan",
                        "url": "https://example.com/not-media",
                        "format_id": "hls-720",
                        "download": False,
                    }
                )
            )
        )
        self.assertIs(response["ok"], False)
        self.assertEqual(response["action"], "resolve_hls_playlist_plan")
        self.assertEqual(response["error"]["code"], "unsupported_site")
        self.assertNotIn("traceback", json.dumps(response).lower())

    def test_playlist_action_is_bounded_flat_and_secret_free(self) -> None:
        result = extractor.extract_playlist(
            {
                "action": "extract_playlist",
                "url": (
                    "https://www.youtube.com/shorts/AbCdEf123_-?"
                    "list=PLFixture_123&si=tracking-secret"
                ),
                "maximum_entries": 25,
                "download": False,
            },
            ydl_factory=_FakePlaylistYoutubeDL,
        )

        self.assertEqual(
            _FakePlaylistYoutubeDL.last_url,
            (
                "https://www.youtube.com/watch?"
                "v=AbCdEf123_-&list=PLFixture_123"
            ),
        )
        self.assertEqual(result["playlist_id"], "PLFixture_123")
        self.assertEqual(result["kind"], "shorts")
        self.assertEqual(result["referenced_video_id"], "AbCdEf123_-")
        self.assertEqual(result["reported_item_count"], 4)
        self.assertEqual(result["estimated_total_bytes"], 4_000)
        self.assertEqual(len(result["entries"]), 4)
        self.assertEqual(result["entries"][0]["availability"], "available")
        self.assertEqual(result["entries"][1]["availability"], "privateVideo")
        self.assertEqual(result["entries"][2]["availability"], "unavailable")
        self.assertIsNone(result["entries"][1]["canonical_url"])
        self.assertEqual(
            result["entries"][3]["canonical_url"],
            "https://www.youtube.com/watch?v=MnOpQr456_-",
        )
        self.assertFalse(result["is_truncated"])

        options = _FakePlaylistYoutubeDL.last_options
        assert options is not None
        self.assertIs(options["skip_download"], True)
        self.assertIs(options["simulate"], True)
        self.assertIs(options["noplaylist"], False)
        self.assertIs(options["extract_flat"], True)
        self.assertIs(options["ignoreerrors"], True)
        self.assertIs(options["ignore_no_formats_error"], True)
        self.assertEqual(options["playlistend"], 26)
        self.assertEqual(options["allowed_extractors"], ["youtube", "youtube:tab", "youtube:playlist"])
        self.assertEqual(options["js_runtimes"], {})
        self.assertEqual(options["remote_components"], set())

        encoded = json.dumps(result, sort_keys=True)
        self.assertNotIn("must-not-leak", encoded)
        self.assertNotIn("tracking-secret", encoded)
        self.assertNotIn("signed.invalid", encoded)
        self.assertNotIn("formats", encoded)

    def test_playlist_url_classification_and_limits(self) -> None:
        cases = (
            (
                "https://youtube.com/playlist?list=PLFixture_123",
                "playlist",
                None,
            ),
            (
                "https://youtube.com/watch?v=AbCdEf123_-&list=RDMM123",
                "mix",
                "AbCdEf123_-",
            ),
            (
                "https://youtube.com/playlist?list=WL",
                "privateCollection",
                None,
            ),
        )
        for url, kind, video_id in cases:
            with self.subTest(url=url):
                intent = extractor._normalize_youtube_playlist_url(url)
                self.assertEqual(intent.kind, kind)
                self.assertEqual(intent.referenced_video_id, video_id)
                self.assertNotIn("v=", intent.canonical_url)

        invalid_cases = (
            "https://youtube.com/playlist",
            "https://youtube.com/channel/UC123?list=PLFixture_123",
            "https://example.com/playlist?list=PLFixture_123",
        )
        for url in invalid_cases:
            with self.subTest(url=url):
                with self.assertRaises(
                    extractor.SafeExtractionFailure
                ):
                    extractor._normalize_youtube_playlist_url(url)

        for limit in (0, 501, True, 2.5):
            with self.subTest(limit=limit):
                with self.assertRaises(
                    extractor.SafeExtractionFailure
                ) as context:
                    extractor.extract_playlist(
                        {
                            "url": (
                                "https://youtube.com/playlist?"
                                "list=PLFixture_123"
                            ),
                            "maximum_entries": limit,
                            "download": False,
                        },
                        ydl_factory=_FakePlaylistYoutubeDL,
                    )
                self.assertEqual(
                    context.exception.code,
                    "invalid_playlist_limit",
                )

    def test_playlist_action_never_silently_exceeds_entry_limit(self) -> None:
        result = extractor.extract_playlist(
            {
                "url": (
                    "https://youtube.com/playlist?"
                    "list=PLFixture_123"
                ),
                "maximum_entries": 2,
                "download": False,
            },
            ydl_factory=_FakePlaylistYoutubeDL,
        )

        self.assertEqual(len(result["entries"]), 2)
        self.assertTrue(result["is_truncated"])

    def test_complete_sensitive_values_are_redacted_from_text(self) -> None:
        source = (
            "Ordinary metadata stays useful.\n"
            "Authorization: Bearer supersecret\n"
            "Cookie: session=abc; other=def\n"
            'token="two words" visible-tail\n'
            "source=https://example.invalid/watch?"
            "token=query-secret&quality=1080p&n=n-secret\n"
            "The words token bucket and Cookie Monster stay visible."
        )

        redacted = extractor._redact_text(source, maximum=4_096)

        assert redacted is not None
        for secret in (
            "supersecret",
            "session=abc",
            "other=def",
            "two words",
            "query-secret",
            "n-secret",
        ):
            with self.subTest(secret=secret):
                self.assertNotIn(secret, redacted)
        self.assertIn("Authorization: [REDACTED]", redacted)
        self.assertIn("Cookie: [REDACTED]", redacted)
        self.assertIn('token=[REDACTED] visible-tail', redacted)
        self.assertIn("quality=1080p", redacted)
        self.assertIn("Ordinary metadata stays useful.", redacted)
        self.assertIn("token bucket", redacted)
        self.assertIn("Cookie Monster", redacted)

    def test_url_validation_rejects_non_media_and_other_hosts(self) -> None:
        cases = (
            ("https://www.youtube.com/", "url_does_not_identify_media"),
            (
                "https://www.youtube.com/playlist?list=fixture",
                "playlist_confirmation_required",
            ),
            ("https://example.com/watch?v=dQw4w9WgXcQ", "unsupported_site"),
            (
                "file:///private/etc/passwd",
                "invalid_url",
            ),
        )
        for url, expected_code in cases:
            with self.subTest(url=url):
                with self.assertRaises(
                    extractor.SafeExtractionFailure
                ) as context:
                    extractor.extract_metadata(
                        {"url": url, "download": False},
                        ydl_factory=_FakeYoutubeDL,
                    )
                self.assertEqual(context.exception.code, expected_code)

    def test_action_cannot_enable_downloads(self) -> None:
        with self.assertRaises(
            extractor.SafeExtractionFailure
        ) as context:
            extractor.extract_metadata(
                {
                    "url": "https://youtu.be/dQw4w9WgXcQ",
                    "download": True,
                },
                ydl_factory=_FakeYoutubeDL,
            )
        self.assertEqual(context.exception.code, "downloads_disabled")

    def test_bridge_returns_a_bounded_typed_error(self) -> None:
        response = json.loads(
            illucet_bridge.handle_request(
                json.dumps(
                    {
                        "action": "extract_metadata",
                        "url": "https://example.com/not-media",
                        "download": False,
                    }
                )
            )
        )
        self.assertIs(response["ok"], False)
        self.assertEqual(response["action"], "extract_metadata")
        self.assertEqual(response["error"]["code"], "unsupported_site")
        self.assertNotIn("traceback", json.dumps(response).lower())

    def test_provider_failure_exposes_only_a_fixed_diagnostic_code(self) -> None:
        failure = provider.IllucetProviderFailure(
            "https://signed.invalid/?token=must-not-leak",
            reason="runtime_reference_error",
        )
        classified = extractor.classify_extraction_error(failure)

        self.assertEqual(
            classified.code,
            "javascript_challenge_failure.runtime_reference_error",
        )
        self.assertNotIn("signed.invalid", classified.message)
        self.assertNotIn("must-not-leak", classified.message)

    def test_runtime_failure_classification_drops_thrown_text(self) -> None:
        reason = provider._classify_runtime_failure(
            RuntimeError(
                "QuickJS safe thrown text: super secret password"
            )
        )

        self.assertEqual(reason, "runtime_error")
        self.assertNotIn("super secret password", reason)


class RecentExtractionTests(unittest.TestCase):
    url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    class Factory(_FakeYoutubeDL):
        calls = 0
        fail = False

        def extract_info(self, url, *, download):
            type(self).calls += 1
            if type(self).fail:
                raise RuntimeError("fixture extraction failed")
            info = (super().extract_info(RecentExtractionTests.url, download=download)
                    if provider._active_extraction_diagnostics.get() is not None else {})
            info["id"] = url.rsplit("=", 1)[-1]
            raw = _FakeStreamYoutubeDL({}).extract_info(RecentExtractionTests.url, download=False)["formats"][0]
            raw["http_headers"] = {"User-Agent": "Illucet fixture"}
            raw["url"] += "&generation=" + str(type(self).calls)
            info["formats"] = [raw]
            return info

    def setUp(self):
        extractor.clear_recent_extractions()
        self.Factory.calls = 0
        self.Factory.fail = False

    def tearDown(self):
        extractor.clear_recent_extractions()

    def analyze(self, **options):
        return extractor.extract_metadata({"url": self.url, "retain_for_download": True, **options},
                                          ydl_factory=self.Factory)

    def resolve(self, **options):
        return extractor.resolve_streams({"url": self.url, "format_ids": ["251"], **options},
                                         ydl_factory=self.Factory)

    def test_immediate_analysis_and_resolution_use_one_extraction(self):
        initial = self.analyze()
        prepared = self.analyze(reuse_recent_extraction=True)
        self.assertEqual(initial, prepared)
        self.assertNotIn("transport-secret", json.dumps(prepared))
        resolved = self.resolve(reuse_token=prepared["reuse_token"])
        self.assertEqual(self.Factory.calls, 1)
        self.assertEqual(resolved["streams"][0]["expected_bytes"], 12345)
        self.assertEqual(resolved["streams"][0]["http_headers"], {"User-Agent": "Illucet fixture"})
        self.assertIn("generation=1", resolved["streams"][0]["url"])
        self.assertFalse(extractor._recent_extractions)
        self.resolve(reuse_token=prepared["reuse_token"])
        self.assertEqual(self.Factory.calls, 2)  # Single use, including a replayed token.

    def test_cached_handoff_preserves_original_not_before_time(self):
        from unittest.mock import patch
        original = self.Factory.extract_info
        deadline = 1_800_000_004
        def with_deadline(factory, *args, **kwargs):
            info = original(factory, *args, **kwargs)
            info["formats"][0]["available_at"] = deadline
            return info
        with patch.object(self.Factory, "extract_info", with_deadline):
            with patch.object(extractor.time, "time", return_value=deadline - 4):
                prepared = self.analyze()
            with patch.object(extractor.time, "time", return_value=deadline - 2):
                resolved = self.resolve(reuse_token=prepared["reuse_token"])
        self.assertEqual(self.Factory.calls, 1)
        self.assertEqual(resolved["streams"][0]["available_at"], deadline)
        self.assertNotIn("available_at", json.dumps(prepared))

    def test_expiry_is_not_extended_by_reading_and_refreshes_once(self):
        from unittest.mock import patch
        with patch.object(extractor.time, "monotonic", return_value=100):
            first = self.analyze()
        with patch.object(extractor.time, "monotonic", return_value=150):
            self.analyze(reuse_recent_extraction=True)
        with patch.object(extractor.time, "monotonic", return_value=161):
            fresh = self.analyze(reuse_recent_extraction=True)
            self.resolve(reuse_token=fresh["reuse_token"])
        self.assertNotEqual(first["reuse_token"], fresh["reuse_token"])
        self.assertEqual(self.Factory.calls, 2)

    def test_retry_resolution_without_token_always_refreshes(self):
        first = self.analyze()
        resolved = self.resolve()
        self.assertEqual(self.Factory.calls, 2)
        self.assertIn("generation=2", resolved["streams"][0]["url"])
        self.assertFalse(extractor._recent_extractions)
        self.resolve(reuse_token=first["reuse_token"])
        self.assertEqual(self.Factory.calls, 3)

    def test_wrong_token_and_different_video_cannot_reuse(self):
        first = self.analyze()
        self.resolve(reuse_token="wrong-token")
        self.assertEqual(self.Factory.calls, 2)
        first = self.analyze()
        resolved = self.resolve(url="https://www.youtube.com/watch?v=AbCdEf123_-", reuse_token=first["reuse_token"])
        self.assertEqual(resolved["video_id"], "AbCdEf123_-")
        self.assertEqual(self.Factory.calls, 4)

    def test_explicit_refresh_failure_invalidates_old_result(self):
        self.analyze()
        self.Factory.fail = True
        with self.assertRaises(RuntimeError):
            self.analyze()
        self.assertFalse(extractor._recent_extractions)

    def test_authenticated_requests_bypass_and_clear_anonymous_handoff(self):
        from unittest.mock import patch
        first = self.analyze()
        with patch.object(extractor.illucet_accounts, "downloader", side_effect=lambda request, factory, options: factory(options)):
            fresh = self.analyze(account_cookies=[], reuse_recent_extraction=True)
            self.resolve(account_cookies=[], reuse_token=first["reuse_token"])
        self.assertNotIn("reuse_token", fresh)
        self.assertEqual(self.Factory.calls, 3)
        self.assertFalse(extractor._recent_extractions)

    def test_cancellation_prevents_reuse_and_memory_is_bounded(self):
        from unittest.mock import patch
        self.analyze()
        with patch.object(extractor._illucet_native, "is_cancelled", return_value=True):
            with self.assertRaises(provider.IllucetProviderCancelled):
                self.analyze(reuse_recent_extraction=True)
        self.assertEqual(self.Factory.calls, 1)
        for video in ["AbCdEf123_" + str(i) for i in range(6)]:
            self.analyze(url="https://www.youtube.com/watch?v=" + video)
        self.assertEqual(len(extractor._recent_extractions), 4)
        self.assertNotIn(self.url, extractor._recent_extractions)
        with patch.object(extractor, "_RECENT_MAX_BYTES", 1):
            self.assertNotIn("reuse_token", self.analyze())

    def test_missing_selected_format_refreshes_instead_of_substituting(self):
        first = self.analyze()
        with self.assertRaises(extractor.SafeExtractionFailure):
            self.resolve(format_ids=["not-available"], reuse_token=first["reuse_token"])
        self.assertEqual(self.Factory.calls, 2)
        self.assertFalse(extractor._recent_extractions)

    def test_credentials_and_drm_are_not_retained(self):
        for extra in [{"http_headers": {"Cookie": "secret"}}, {"has_drm": True}]:
            with self.subTest(extra=extra):
                info = {"id": "dQw4w9WgXcQ", "formats": [{"format_id": "251", "protocol": "https",
                    "url": "https://rr1.googlevideo.com/media", **extra}]}
                result = {}
                extractor._remember_extraction(self.url, {"retain_for_download": True}, info, result)
                self.assertNotIn("reuse_token", result)
                self.assertFalse(extractor._recent_extractions)


if __name__ == "__main__":
    unittest.main()
