#!/usr/bin/env python3
"""Exercise publication state transitions without contacting GitHub."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('publisher', Path(__file__).resolve().parents[1] / 'publish-release.py')
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)
TAG = 'v1.0.5'
SHA = 'a' * 40


def bundle(seed=b'original'):
    result = {name: seed + name.encode() for name in publisher.PAYLOADS}
    result[publisher.MANIFEST] = ''.join(
        f'{hashlib.sha256(data).hexdigest()}  {name}\n' for name, data in result.items()).encode()
    return result


class FakeGitHub:
    def __init__(self, data=None, draft=False):
        self.exists = data is not None
        self.data = dict(data or {})
        self.draft = draft
        self.mutations = []
        self.sha = SHA
        self.failure = None

    def tag_commit(self, tag):
        return self.sha

    def release(self, tag):
        if self.failure:
            raise publisher.ReleaseError(self.failure)
        if not self.exists:
            return None
        return {'tag_name': tag, 'draft': self.draft, 'assets': [
            {'id': i, 'name': name, 'state': 'uploaded', 'size': len(data)}
            for i, (name, data) in enumerate(self.data.items())]}

    def download(self, asset, destination):
        destination.write_bytes(self.data[asset['name']])

    def create(self, tag):
        self.mutations.append('create')
        self.exists = True
        self.draft = True

    def upload(self, tag, path):
        self.mutations.append(('upload', path.name))
        if path.name in self.data:
            raise AssertionError('Must never replace an asset')
        self.data[path.name] = path.read_bytes()

    def publish(self, tag):
        self.mutations.append('publish')
        self.draft = False


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.data = bundle()
        for name, data in self.data.items():
            (self.directory / name).write_bytes(data)

    def run_publish(self, api, **kwargs):
        return publisher.run(api, TAG, SHA, self.directory, **kwargs)

    def test_new_release_is_drafted_verified_then_published(self):
        api = FakeGitHub()
        self.assertIn('Published', self.run_publish(api))
        self.assertEqual(api.mutations, ['create', *[('upload', n) for n in publisher.ASSETS], 'publish'])
        self.assertEqual(api.data, self.data)

    def test_repeat_published_release_is_read_only(self):
        api = FakeGitHub(self.data)
        self.assertIn('Already published', self.run_publish(api))
        self.assertEqual(api.mutations, [])

    def test_existing_release_uses_its_own_checksums_not_rebuild(self):
        api = FakeGitHub(bundle(b'other-build'))
        self.assertIn('Already published', self.run_publish(api))
        self.assertEqual(api.mutations, [])

    def test_read_only_verification_needs_no_local_artifacts(self):
        api = FakeGitHub(self.data)
        publisher.run(api, TAG, SHA, verify_only=True)
        self.assertEqual(api.mutations, [])

    def test_read_only_rejects_missing_or_draft_release(self):
        for api in (FakeGitHub(), FakeGitHub(self.data, draft=True)):
            with self.assertRaisesRegex(publisher.ReleaseError, 'published release'):
                self.run_publish(api, verify_only=True)
            self.assertEqual(api.mutations, [])

    def test_incomplete_published_release_is_not_repaired_silently(self):
        api = FakeGitHub({publisher.MANIFEST: self.data[publisher.MANIFEST]})
        with self.assertRaisesRegex(publisher.ReleaseError, 'incomplete'):
            self.run_publish(api)
        self.assertEqual(api.mutations, [])

    def test_corrupt_published_release_fails(self):
        api = FakeGitHub({**self.data, 'Illucet.ipa': b'corrupt'})
        with self.assertRaisesRegex(publisher.ReleaseError, 'Checksum mismatch'):
            self.run_publish(api)
        self.assertEqual(api.mutations, [])

    def test_partial_draft_resumes_missing_assets_only(self):
        api = FakeGitHub({'Illucet.ipa': self.data['Illucet.ipa']}, draft=True)
        self.run_publish(api)
        self.assertNotIn(('upload', 'Illucet.ipa'), api.mutations)
        self.assertEqual(api.data, self.data)
        self.assertFalse(api.draft)

    def test_conflicting_draft_fails_before_any_upload(self):
        api = FakeGitHub({'Illucet.ipa': b'different'}, draft=True)
        with self.assertRaisesRegex(publisher.ReleaseError, 'conflicts'):
            self.run_publish(api)
        self.assertEqual(api.mutations, [])

    def test_failed_upload_leaves_resumable_draft(self):
        api = FakeGitHub()
        real_upload = api.upload
        def interrupted(tag, path):
            if path.name == publisher.MANIFEST:
                raise publisher.ReleaseError('upload interrupted')
            real_upload(tag, path)
        api.upload = interrupted
        with self.assertRaisesRegex(publisher.ReleaseError, 'interrupted'):
            self.run_publish(api)
        self.assertTrue(api.draft)
        self.assertNotIn('publish', api.mutations)
        api.upload = real_upload
        self.run_publish(api)
        self.assertFalse(api.draft)

    def test_invalid_local_payload_never_creates_release(self):
        (self.directory / 'Illucet.ipa').write_bytes(b'corrupt')
        api = FakeGitHub()
        with self.assertRaises(publisher.ReleaseError):
            self.run_publish(api)
        self.assertEqual(api.mutations, [])

    def test_manifest_rejects_paths_duplicates_and_missing_entries(self):
        good = self.data[publisher.MANIFEST].decode()
        for bad in (good.replace('Illucet.ipa', '../Illucet.ipa'), good + good,
                    good.splitlines()[0], 'malformed'):
            (self.directory / publisher.MANIFEST).write_text(bad)
            with self.subTest(manifest=bad), self.assertRaises(publisher.ReleaseError):
                publisher.verify_bundle(self.directory)

    def test_symbolic_link_input_is_rejected(self):
        path = self.directory / 'Illucet.ipa'
        path.unlink()
        path.symlink_to(self.directory / 'ThirdPartyNotices.txt')
        with self.assertRaisesRegex(publisher.ReleaseError, 'unsafe'):
            publisher.verify_bundle(self.directory)

    def test_wrong_source_commit_stops_before_mutation(self):
        api = FakeGitHub()
        api.sha = 'b' * 40
        with self.assertRaisesRegex(publisher.ReleaseError, 'source commit'):
            self.run_publish(api)
        self.assertEqual(api.mutations, [])

    def test_moved_tag_during_upload_keeps_draft(self):
        api = FakeGitHub()
        upload = api.upload
        def move_tag(tag, path):
            upload(tag, path)
            api.sha = 'b' * 40
        api.upload = move_tag
        with self.assertRaisesRegex(publisher.ReleaseError, 'source commit'):
            self.run_publish(api)
        self.assertTrue(api.draft)
        self.assertNotIn('publish', api.mutations)

    def test_api_failure_never_becomes_create(self):
        api = FakeGitHub()
        api.failure = 'HTTP 503'
        with self.assertRaises(publisher.ReleaseError):
            self.run_publish(api)
        self.assertEqual(api.mutations, [])

    def test_duplicate_or_incomplete_remote_assets_rejected(self):
        release = FakeGitHub(self.data).release(TAG)
        variants = [copy.deepcopy(release) for _ in range(3)]
        variants[0]['assets'].append(variants[0]['assets'][0])
        variants[1]['assets'][0]['state'] = 'starter'
        variants[2]['assets'][0]['size'] = 0
        for variant in variants:
            with self.assertRaises(publisher.ReleaseError):
                publisher.asset_map(variant, TAG)

    @patch('subprocess.run')
    def test_api_only_treats_explicit_404_as_missing(self, command):
        api = publisher.GitHub('example/Illucet')
        for message in ('HTTP 403', 'HTTP 500', 'connection failed'):
            command.return_value = subprocess.CompletedProcess([], 1, '', message)
            with self.assertRaises(publisher.ReleaseError):
                api.release(TAG)
        command.return_value = subprocess.CompletedProcess([], 1, '', 'gh: Not Found (HTTP 404)')
        self.assertIsNone(api.release(TAG))

    @patch('subprocess.run')
    def test_annotated_tag_is_resolved(self, command):
        command.side_effect = [subprocess.CompletedProcess([], 0,
            '{"object":{"type":"tag","sha":"tag-object"}}', ''),
            subprocess.CompletedProcess([], 0,
            '{"object":{"type":"commit","sha":"' + SHA + '"}}', '')]
        self.assertEqual(publisher.GitHub('example/Illucet').tag_commit(TAG), SHA)


if __name__ == '__main__':
    unittest.main()
