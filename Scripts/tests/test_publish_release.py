#!/usr/bin/env python3
"""Exercise publication state transitions without contacting GitHub."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location('publisher', Path(__file__).resolve().parents[1] / 'publish-release.py')
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)
TAG = 'v1.0.5'
SHA = 'a' * 40


def bundle(seed=b'original', *, version=TAG[1:], profile=False):
    result = {name: seed + name.encode() for name in publisher.PAYLOADS}
    ipa = io.BytesIO()
    with zipfile.ZipFile(ipa, 'w') as archive:
        archive.writestr('Payload/Illucet.app/Info.plist', plistlib.dumps({
            'CFBundleIdentifier': 'com.local.illucet',
            'CFBundleShortVersionString': version,
            'CFBundleVersion': '8',
            'MinimumOSVersion': '26.0',
            'NSPhotoLibraryAddUsageDescription': 'Save selected media to Photos.',
        }))
        archive.writestr('Payload/Illucet.app/PlugIns/IllucetActivity.appex/Info.plist',
                         plistlib.dumps({'NSMicrophoneUsageDescription': 'Test extension permission.'}))
        archive.writestr('Payload/Illucet.app/Illucet', seed)
        if profile:
            archive.writestr('Payload/Illucet.app/embedded.mobileprovision', b'test profile')
    result[publisher.IPA] = ipa.getvalue()
    result[publisher.MANIFEST] = ''.join(
        f'{hashlib.sha256(data).hexdigest()}  {name}\n' for name, data in result.items()).encode()
    return result


class FakeGitHub:
    repo = 'example/Illucet'

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
        return {'tag_name': tag, 'draft': self.draft, 'created_at': '2026-11-09T00:00:00Z',
                'body': 'Added a new download option.', 'assets': [
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
        self.assertEqual({name: api.data[name] for name in self.data}, self.data)
        source = json.loads(api.data[publisher.STORE_SOURCE])
        app, = source['apps']
        version, = app['versions']
        release_root = f'https://github.com/{api.repo}/releases'
        self.assertEqual(source['sourceURL'], f'{release_root}/latest/download/{publisher.STORE_SOURCE}')
        self.assertEqual(app['bundleIdentifier'], 'com.local.illucet')
        self.assertNotIn('marketplaceID', app)
        self.assertEqual(version['downloadURL'], f'{release_root}/download/{TAG}/{publisher.IPA}')
        self.assertEqual((version['version'], version['buildVersion'], version['minOSVersion']), ('1.0.5', '8', '26.0'))
        self.assertEqual(version['size'], len(self.data[publisher.IPA]))
        self.assertEqual(version['sha256'], hashlib.sha256(self.data[publisher.IPA]).hexdigest())
        self.assertEqual(app['appPermissions']['privacy'], {
            'NSPhotoLibraryAddUsageDescription': 'Save selected media to Photos.',
            'NSMicrophoneUsageDescription': 'Test extension permission.',
        })
        self.assertIn('com.apple.security.application-groups', app['appPermissions']['entitlements'])

    def test_next_release_keeps_the_feed_url_and_links_its_own_ipa(self):
        older = FakeGitHub()
        self.run_publish(older)
        for name, data in bundle(version='1.1.0').items():
            (self.directory / name).write_bytes(data)
        newer = FakeGitHub()
        publisher.run(newer, 'v1.1.0', SHA, self.directory)
        old_feed = json.loads(older.data[publisher.STORE_SOURCE])
        new_feed = json.loads(newer.data[publisher.STORE_SOURCE])
        self.assertEqual(new_feed['sourceURL'], old_feed['sourceURL'])
        version, = new_feed['apps'][0]['versions']
        self.assertEqual(version['version'], '1.1.0')
        self.assertIn('/releases/download/v1.1.0/', version['downloadURL'])
        self.assertEqual(version['sha256'], hashlib.sha256(newer.data[publisher.IPA]).hexdigest())

    def test_rejects_published_source_pointing_to_different_ipa(self):
        api = FakeGitHub()
        self.run_publish(api)
        source = json.loads(api.data[publisher.STORE_SOURCE])
        source['apps'][0]['versions'][0]['sha256'] = 'a' * 64
        api.data[publisher.STORE_SOURCE] = json.dumps(source).encode()
        api.mutations.clear()
        with self.assertRaisesRegex(publisher.ReleaseError, 'source does not match'):
            self.run_publish(api, verify_only=True)
        self.assertEqual(api.mutations, [])

    def test_wrong_version_or_signing_profile_blocks_upload(self):
        for data, message in ((bundle(version='2.0.0'), 'version does not match'),
                              (bundle(profile=True), 'without signing profiles')):
            for name, content in data.items():
                (self.directory / name).write_bytes(content)
            api = FakeGitHub({}, draft=True)
            with self.subTest(message=message), self.assertRaisesRegex(publisher.ReleaseError, message):
                self.run_publish(api)
            self.assertEqual(api.mutations, [])

    def test_release_creation_uses_versioned_notes_when_present(self):
        root = self.directory / 'repository'
        notes = root / 'docs' / 'releases' / '1.1.0.md'
        notes.parent.mkdir(parents=True)
        notes.write_text('Release changes\n\nInstallation requirements.\n')
        api = publisher.GitHub('example/Illucet')
        with patch.object(publisher, '__file__', str(root / 'Scripts' / 'publish-release.py')), patch.object(api, 'command') as command:
            api.create('v1.1.0')
        command.assert_called_once_with('release', 'create', 'v1.1.0', '--verify-tag', '--draft',
                                        '--title', 'Illucet 1.1.0', '--notes-file', str(notes.resolve()))

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
        self.assertEqual({name: api.data[name] for name in self.data}, self.data)
        self.assertIn(publisher.STORE_SOURCE, api.data)
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
        command.side_effect = [
            subprocess.CompletedProcess([], 1, '', 'gh: Not Found (HTTP 404)'),
            subprocess.CompletedProcess([], 0, '[]', ''),
        ]
        self.assertIsNone(api.release(TAG))

    def test_published_lookup_does_not_enumerate_releases(self):
        api = publisher.GitHub('example/Illucet')
        published = {'tag_name': TAG, 'draft': False}
        with patch.object(api, 'api', return_value=published) as request:
            self.assertIs(api.release(TAG), published)
        request.assert_called_once_with(f'releases/tags/{TAG}', missing_ok=True)

    def test_draft_lookup_paginates_after_published_endpoint_returns_missing(self):
        api = publisher.GitHub('example/Illucet')
        draft = {'tag_name': TAG, 'draft': True, 'id': 123}
        first_page = [{'tag_name': f'other-{i}', 'draft': False} for i in range(100)]
        with patch.object(api, 'api', side_effect=[None, first_page, [draft]]) as request:
            self.assertIs(api.release(TAG), draft)
        self.assertEqual([call.args[0] for call in request.call_args_list],
                         [f'releases/tags/{TAG}', 'releases?per_page=100&page=1',
                          'releases?per_page=100&page=2'])

    def test_draft_lookup_stops_after_partial_page_and_rejects_duplicate_tags(self):
        api = publisher.GitHub('example/Illucet')
        draft = {'tag_name': TAG, 'draft': True}
        with patch.object(api, 'api', side_effect=[None, [{'tag_name': 'other'}]]) as request:
            self.assertIsNone(api.release(TAG))
            self.assertEqual(request.call_count, 2)
        with patch.object(api, 'api', side_effect=[None, [draft, draft]]):
            with self.assertRaisesRegex(publisher.ReleaseError, 'Multiple releases'):
                api.release(TAG)

    @patch('subprocess.run')
    def test_annotated_tag_is_resolved(self, command):
        command.side_effect = [subprocess.CompletedProcess([], 0,
            '{"object":{"type":"tag","sha":"tag-object"}}', ''),
            subprocess.CompletedProcess([], 0,
            '{"object":{"type":"commit","sha":"' + SHA + '"}}', '')]
        self.assertEqual(publisher.GitHub('example/Illucet').tag_commit(TAG), SHA)


if __name__ == '__main__':
    unittest.main()
