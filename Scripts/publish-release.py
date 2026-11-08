#!/usr/bin/env python3
"""Publish verified release assets, or verify an existing release without replacing it.

Requires gh authentication. --verify-existing never creates or edits a release.
A published release is checked against its own manifest: rebuilding the same
source on another machine need not produce byte-identical archives.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

PAYLOADS = ('Illucet.ipa', 'ThirdPartyNotices.txt', 'Illucet-native-sources.tar.gz')
MANIFEST = 'SHA256SUMS.txt'
ASSETS = (*PAYLOADS, MANIFEST)
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
    for name in ASSETS:
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
        return self.api(f'releases/tags/{tag}', missing_ok=True)

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
        self.command('release', 'create', tag, '--verify-tag', '--draft',
                     '--title', f'Illucet {tag[1:]}', '--notes', NOTES)

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


def verify_remote(api, release: dict, tag: str, directory: Path) -> None:
    assets = asset_map(release, tag)
    missing = set(ASSETS) - assets.keys()
    if missing:
        raise ReleaseError('Published release is incomplete: ' + ', '.join(sorted(missing)))
    for name in ASSETS:
        api.download(assets[name], directory / name)
    verify_bundle(directory)


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
    # Check every existing asset before making any upload, including the manifest.
    with tempfile.TemporaryDirectory(prefix='illucet-draft-check-') as tmp:
        for name, asset in assets.items():
            target = Path(tmp) / name
            api.download(asset, target)
            if digest(target) != digest(directory / name):
                raise ReleaseError(f'Draft asset conflicts with this build: {name}')
    for name in ASSETS:
        if name not in assets:
            api.upload(tag, directory / name)
    release = api.release(tag)
    if release is None or not release['draft']:
        raise ReleaseError('Draft changed during publication; inspect before retrying')
    with tempfile.TemporaryDirectory(prefix='illucet-upload-check-') as tmp:
        verify_remote(api, release, tag, Path(tmp))
        for name in ASSETS:
            if digest(Path(tmp) / name) != digest(directory / name):
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
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Release verification failed: {error}\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
