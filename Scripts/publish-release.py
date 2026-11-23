#!/usr/bin/env python3
"""Publish verified release assets, or verify an existing release without replacing it.

Requires gh authentication. --verify-existing never creates or edits a release.
A published release is checked against its own manifest: rebuilding the same
source on another machine need not produce byte-identical archives.
"""
from __future__ import annotations

import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
IPA = 'Illucet.ipa'
PAYLOADS = (IPA, 'ThirdPartyNotices.txt', 'Illucet-native-sources.tar.gz')
MANIFEST = 'SHA256SUMS.txt'
CHECKSUM_ASSETS = (*PAYLOADS, MANIFEST)
STORE_SOURCE = 'illucet-source.json'
ASSETS = (*CHECKSUM_ASSETS, STORE_SOURCE)
NOTES = ('On-device downloads for iPhone and iPad (iOS 26+). The IPA is unsigned; '
         'use your own sideloading/signing setup. Source code, native source inputs, '
         'license notices and checksums accompany this release.')


class ReleaseError(RuntimeError):
    pass


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def checked_file(path: Path) -> None:
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise ReleaseError(f'Missing, empty or unsafe asset: {path.name}')


def verify_bundle(directory: Path) -> None:
    for name in CHECKSUM_ASSETS:
        checked_file(directory / name)
    manifest = directory / MANIFEST
    if manifest.stat().st_size > 4096:
        raise ReleaseError('Checksum manifest is too large')
    expected = {}
    for line in manifest.read_text().splitlines():
        match = re.fullmatch(r'([a-fA-F0-9]{64}) [ *](.+)', line)
        if not match or match[2] not in PAYLOADS or match[2] in expected:
            raise ReleaseError('Invalid, duplicate or unexpected checksum entry')
        expected[match[2]] = match[1].lower()
    if set(expected) != set(PAYLOADS):
        raise ReleaseError('Checksum manifest must cover all three payloads')
    for name, checksum in expected.items():
        if digest(directory / name) != checksum:
            raise ReleaseError(f'Checksum mismatch: {name}')


def store_source(repo: str, release: dict, ipa: Path) -> dict:
    tag = release['tag_name']
    app_path = 'Payload/Illucet.app'
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        extension_plist = re.compile(rf'{re.escape(app_path)}/PlugIns/[^/]+\.appex/Info\.plist')
        plists = [f'{app_path}/Info.plist'] + sorted(name for name in names if extension_plist.fullmatch(name))
        for name in plists:
            bundle = name.removesuffix('/Info.plist')
            if f'{bundle}/_CodeSignature/CodeResources' in names:
                raise ReleaseError('The Store source must reference an unsigned app and extensions')
        if any(name.lower().endswith(('.mobileprovision', '.provisionprofile')) for name in names):
            raise ReleaseError('The Store source must reference an IPA without signing profiles')
        info, *extensions = [plistlib.loads(archive.read(name)) for name in plists]

    bundle_id = info['CFBundleIdentifier']
    version = info['CFBundleShortVersionString']
    build = info['CFBundleVersion']
    minimum_os = info['MinimumOSVersion']
    if bundle_id != 'com.local.illucet' or tag != f'v{version}':
        raise ReleaseError('IPA bundle identifier or version does not match the Illucet release')
    if any(not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value)
           for value in (build, minimum_os)):
        raise ReleaseError('IPA build number and minimum OS must be valid versions')
    privacy = {}
    for target in (info, *extensions):
        for key, description in target.items():
            if not key.endswith('UsageDescription'):
                continue
            if not isinstance(description, str) or not description.strip():
                raise ReleaseError(f'IPA has no privacy explanation for {key}')
            if key in privacy and privacy[key] != description:
                raise ReleaseError(f'IPA has conflicting privacy explanations for {key}')
            privacy[key] = description
    with (ROOT / 'Config/Illucet-Shared.entitlements').open('rb') as stream:
        entitlements = sorted(plistlib.load(stream))

    website = f'https://github.com/{repo}'
    download = f'{website}/releases/download/{tag}/{IPA}'
    icon = f'https://raw.githubusercontent.com/{repo}/main/Design/Brand/Illucet-Light.png'
    return {
        'name': 'Illucet',
        'identifier': 'com.local.illucet.source',
        'sourceURL': f'{website}/releases/latest/download/{STORE_SOURCE}',
        'iconURL': icon,
        'website': website,
        'apps': [{
            'name': 'Illucet',
            'bundleIdentifier': bundle_id,
            'developerName': repo.split('/')[0],
            'subtitle': 'On-device media downloader',
            'localizedDescription': ('Save video, audio and images on iPhone and iPad. '
                                     'Import a list of links, manage a download queue and save to Files or Photos.'),
            'iconURL': icon,
            'category': 'utilities',
            'downloadURL': download,
            'versions': [{
                'version': version,
                'buildVersion': build,
                # GitHub's creation date stays fixed when the draft is published or resumed.
                'date': date.fromisoformat(release['created_at'][:10]).isoformat(),
                'localizedDescription': release.get('body') or f'Illucet {version}',
                'downloadURL': download,
                'size': ipa.stat().st_size,
                'sha256': digest(ipa),
                'minOSVersion': minimum_os,
            }],
            'appPermissions': {'entitlements': entitlements, 'privacy': privacy},
        }],
    }


class GitHub:
    def __init__(self, repo: str):
        self.repo = repo

    def command(self, *args: str) -> None:
        result = subprocess.run(['gh', *args, '--repo', self.repo], capture_output=True, text=True)
        if result.returncode:
            raise ReleaseError(f'GitHub command failed: {result.stderr.strip()}')

    def api(self, endpoint: str, *, missing_ok: bool = False):
        result = subprocess.run(['gh', 'api', f'repos/{self.repo}/{endpoint}'],
                                capture_output=True, text=True)
        if result.returncode:
            if missing_ok and '(HTTP 404)' in result.stderr:
                return None
            raise ReleaseError(f'GitHub API request failed: {result.stderr.strip()}')
        return json.loads(result.stdout)

    def tag_commit(self, tag: str) -> str:
        obj = self.api(f'git/ref/tags/{tag}')['object']
        for _ in range(8):
            if obj['type'] == 'commit':
                return obj['sha']
            if obj['type'] != 'tag':
                break
            obj = self.api(f"git/tags/{obj['sha']}")['object']
        raise ReleaseError('Tag does not resolve to a commit')

    def release(self, tag: str):
        published = self.api(f'releases/tags/{tag}', missing_ok=True)
        if published is not None:
            return published
        # The by-tag endpoint returns published releases. Drafts are visible
        # in the authenticated release inventory for users with push access.
        page = 1
        while True:
            releases = self.api(f'releases?per_page=100&page={page}')
            matches = [release for release in releases if release['tag_name'] == tag]
            if len(matches) > 1:
                raise ReleaseError('Multiple releases use the requested tag')
            if matches:
                return matches[0]
            if len(releases) < 100:
                return None
            page += 1

    def download(self, asset: dict, destination: Path) -> None:
        with destination.open('wb') as stream:
            result = subprocess.run(['gh', 'api',
                f"repos/{self.repo}/releases/assets/{asset['id']}",
                '-H', 'Accept: application/octet-stream'], stdout=stream, stderr=subprocess.PIPE)
        if result.returncode:
            raise ReleaseError(f"Asset download failed: {asset['name']}")
        if destination.stat().st_size != asset['size']:
            raise ReleaseError(f"Asset size mismatch: {asset['name']}")

    def create(self, tag: str) -> None:
        notes = Path(__file__).resolve().parents[1] / 'docs' / 'releases' / f'{tag[1:]}.md'
        notes_arguments = ('--notes-file', str(notes)) if notes.is_file() else ('--notes', NOTES)
        self.command('release', 'create', tag, '--verify-tag', '--draft',
                     '--title', f'Illucet {tag[1:]}', *notes_arguments)

    def upload(self, tag: str, path: Path) -> None:
        # Never use --clobber: previously uploaded files must stay intact.
        self.command('release', 'upload', tag, str(path))

    def publish(self, tag: str) -> None:
        self.command('release', 'edit', tag, '--draft=false')


def check_tag(api, tag: str, expected_sha: str) -> None:
    if api.tag_commit(tag) != expected_sha:
        raise ReleaseError('Release tag does not match the expected source commit')


def asset_map(release: dict, tag: str) -> dict:
    if release['tag_name'] != tag:
        raise ReleaseError('Release tag mismatch')
    assets = {}
    for asset in release['assets']:
        name = asset['name']
        if name not in ASSETS:
            continue
        if name in assets or asset['state'] != 'uploaded' or asset['size'] <= 0:
            raise ReleaseError(f'Duplicate, empty or incomplete asset: {name}')
        assets[name] = asset
    return assets


def verify_remote(api, release: dict, tag: str, directory: Path, *, require_store_source=False) -> None:
    assets = asset_map(release, tag)
    names = ASSETS if require_store_source or STORE_SOURCE in assets else CHECKSUM_ASSETS
    missing = set(names) - assets.keys()
    if missing:
        raise ReleaseError('Published release is incomplete: ' + ', '.join(sorted(missing)))
    for name in names:
        api.download(assets[name], directory / name)
    verify_bundle(directory)
    if STORE_SOURCE in names:
        expected = store_source(api.repo, release, directory / IPA)
        source = json.loads((directory / STORE_SOURCE).read_text())
        app, = source['apps']
        version, = app['versions']
        expected_app = expected['apps'][0]
        if (source.get('sourceURL') != expected['sourceURL']
                or app.get('marketplaceID') is not None
                or any(app.get(key) != expected_app[key]
                       for key in ('bundleIdentifier', 'downloadURL', 'appPermissions'))
                or any(version.get(key) != expected_value for key, expected_value in expected_app['versions'][0].items()
                       if key != 'localizedDescription')):
            raise ReleaseError('Store source does not match the uploaded IPA')


def run(api, tag: str, expected_sha: str, directory: Path | None = None,
        *, verify_only: bool = False) -> str:
    check_tag(api, tag, expected_sha)
    release = api.release(tag)
    if release is not None and not release['draft']:
        with tempfile.TemporaryDirectory(prefix='illucet-release-check-') as tmp:
            verify_remote(api, release, tag, Path(tmp))
        check_tag(api, tag, expected_sha)
        return 'Already published; existing assets and checksums verified.'
    if verify_only:
        raise ReleaseError('A published release is required for read-only verification')
    if directory is None:
        raise ReleaseError('An artifact directory is required to publish')
    verify_bundle(directory)
    if release is None:
        api.create(tag)
        release = api.release(tag)
    if release is None or not release['draft']:
        raise ReleaseError('Expected a draft release; retry to inspect current state')
    assets = asset_map(release, tag)
    with tempfile.TemporaryDirectory(prefix='illucet-draft-check-') as tmp:
        source = Path(tmp) / STORE_SOURCE
        listing = store_source(api.repo, release, directory / IPA)
        source.write_text(json.dumps(listing, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        subprocess.run(['python3', str(ROOT / 'Scripts/verify-public-package.py'), str(source)], check=True)
        files = {name: directory / name for name in CHECKSUM_ASSETS} | {STORE_SOURCE: source}
        # Check every existing asset before uploading, so a retry can only fill missing files.
        existing = Path(tmp) / 'uploaded'
        existing.mkdir()
        for name, asset in assets.items():
            target = existing / name
            api.download(asset, target)
            if digest(target) != digest(files[name]):
                raise ReleaseError(f'Draft asset conflicts with this build: {name}')
        for name, path in files.items():
            if name not in assets:
                api.upload(tag, path)
        release = api.release(tag)
        if release is None or not release['draft']:
            raise ReleaseError('Draft changed during publication; inspect before retrying')
        with tempfile.TemporaryDirectory(prefix='illucet-upload-check-') as uploaded:
            verify_remote(api, release, tag, Path(uploaded), require_store_source=True)
            for name, path in files.items():
                if digest(Path(uploaded) / name) != digest(path):
                    raise ReleaseError(f'Uploaded asset differs from this build: {name}')
    check_tag(api, tag, expected_sha)
    api.publish(tag)
    return 'Published verified unsigned release.'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--expected-sha', required=True)
    parser.add_argument('--artifacts', type=Path)
    parser.add_argument('--verify-existing', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        parser.error('expected an owner/repository name')
    if not re.fullmatch(r'v[0-9]+(?:\.[0-9]+){1,3}', args.tag):
        parser.error('expected a numeric version tag such as v1.0.5')
    if not re.fullmatch(r'[a-f0-9]{40}', args.expected_sha):
        parser.error('expected a full source commit SHA')
    try:
        print(run(GitHub(args.repo), args.tag, args.expected_sha, args.artifacts,
                  verify_only=args.verify_existing))
    except (ReleaseError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile,
            subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release verification failed: {error}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
