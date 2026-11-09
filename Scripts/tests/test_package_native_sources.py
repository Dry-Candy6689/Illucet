#!/usr/bin/env python3
import hashlib
import http.client
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sources', Path(__file__).resolve().parents[1] / 'package-native-sources.py')
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)

class SourceDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'source.tar.gz'
        self.data = b'verified upstream source'
        self.sha = hashlib.sha256(self.data).hexdigest()

    def download(self):
        sources.download_source('https://example.invalid/source.tar.gz', self.path, self.sha)

    @patch.object(sources.time, 'sleep')
    @patch.object(sources.urllib.request, 'urlopen')
    def test_connection_reset_is_retried(self, open_url, sleep):
        open_url.side_effect = [urllib.error.URLError(ConnectionResetError('reset')), io.BytesIO(self.data)]
        self.download()
        self.assertEqual(self.path.read_bytes(), self.data)
        self.assertEqual(open_url.call_count, 2)
        self.assertEqual(list(self.path.parent.glob('*.part')), [])

    @patch.object(sources.time, 'sleep')
    @patch.object(sources.urllib.request, 'urlopen')
    def test_retries_are_bounded_and_leave_no_cache(self, open_url, sleep):
        open_url.side_effect = TimeoutError('timeout')
        with self.assertRaises(TimeoutError):
            self.download()
        self.assertEqual(open_url.call_count, 3)
        self.assertEqual(list(self.path.parent.iterdir()), [])

    @patch.object(sources.urllib.request, 'urlopen')
    def test_digest_mismatch_is_not_retried_or_cached(self, open_url):
        open_url.return_value = io.BytesIO(b'incorrect')
        with self.assertRaises(ValueError):
            self.download()
        self.assertEqual(open_url.call_count, 1)
        self.assertEqual(list(self.path.parent.iterdir()), [])

    @patch.object(sources.time, 'sleep')
    @patch.object(sources.urllib.request, 'urlopen')
    def test_permanent_http_failure_is_not_retried(self, open_url, sleep):
        open_url.side_effect = urllib.error.HTTPError('https://example.invalid', 404, 'missing', {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            self.download()
        self.assertEqual(open_url.call_count, 1)
        sleep.assert_not_called()

    @patch.object(sources.time, 'sleep')
    @patch.object(sources.urllib.request, 'urlopen')
    def test_partial_read_is_discarded_before_retry(self, open_url, sleep):
        class Partial(io.BytesIO):
            def read(self, size=-1):
                if self.tell():
                    raise http.client.IncompleteRead(b'partial')
                return super().read(3)
        open_url.side_effect = [Partial(self.data), io.BytesIO(self.data)]
        self.download()
        self.assertEqual(self.path.read_bytes(), self.data)
        self.assertEqual(list(self.path.parent.glob('*.part')), [])

    @patch.object(sources.time, 'sleep')
    @patch.object(sources.urllib.request, 'urlopen')
    def test_transient_http_failure_is_retried(self, open_url, sleep):
        open_url.side_effect = [urllib.error.HTTPError('https://example.invalid', 503, 'unavailable', {}, None), io.BytesIO(self.data)]
        self.download()
        self.assertEqual(open_url.call_count, 2)

if __name__ == '__main__':
    unittest.main()
