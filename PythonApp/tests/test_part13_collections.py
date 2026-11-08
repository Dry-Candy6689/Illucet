import unittest
import illucet_ytdlp_extractor as extractor


class CreatorCollectionTests(unittest.TestCase):
    def test_creator_tabs_are_bounded_canonical_intents(self):
        for tab, kind in [('videos', 'creatorUploads'), ('shorts', 'creatorShorts'), ('streams', 'creatorReplays')]:
            intent = extractor._normalize_youtube_playlist_url('https://youtube.com/@Fixture/' + tab)
            self.assertEqual(intent.kind, kind)
            self.assertEqual(intent.canonical_url, 'https://www.youtube.com/@Fixture/' + tab)
            self.assertEqual(intent.playlist_id, '@Fixture/' + tab)

    def test_replays_exclude_ongoing_and_unknown_streams(self):
        intent = extractor._normalize_youtube_playlist_url('https://youtube.com/@Fixture/streams')
        entries = [dict(id='dQw4w9WgXcQ', title='Fixture', live_status=status)
                   for status in ['was_live', 'is_live', 'is_upcoming', None]]
        result = extractor._sanitize_playlist({'title': 'Creator', 'entries': entries}, intent=intent, maximum_entries=3)
        self.assertTrue(result['is_truncated'])
        self.assertEqual([e['availability'] for e in result['entries']], ['available', 'unavailable', 'unavailable'])

    def test_bundled_registry_includes_tab_and_playlist_extractors(self):
        from yt_dlp import YoutubeDL
        options = extractor._playlist_options(extractor._SafeLogger(), maximum_entries=3)
        with YoutubeDL(options) as ydl:
            self.assertEqual(set(ydl._ies), {'Youtube', 'YoutubeTab', 'YoutubePlaylist'})
            self.assertTrue(any(ie.suitable('https://www.youtube.com/@NASA/videos') for ie in ydl._ies.values()))

    def test_unknown_fields_are_not_guessed(self):
        intent = extractor._normalize_youtube_playlist_url('https://youtube.com/@Fixture/videos')
        result = extractor._sanitize_playlist({'entries': [{'id': 'dQw4w9WgXcQ', 'title': 'Fixture'}]}, intent=intent, maximum_entries=2)
        entry = result['entries'][0]
        for key in ['upload_date', 'height', 'is_short', 'is_live', 'estimated_bytes']:
            self.assertIsNone(entry[key])
