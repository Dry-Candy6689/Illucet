#!/bin/sh

set -eu

cd "$(dirname "$0")/.."
python3 - <<'PY'
import json
from pathlib import Path
import subprocess

catalog = Path('IllucetApp/Assets.xcassets')

def require(condition, message):
    if not condition:
        raise SystemExit(str(message))

def images(folder):
    metadata = json.loads((folder / 'Contents.json').read_text())
    result = {}
    for entry in metadata['images']:
        appearance = next((a['value'] for a in entry.get('appearances', [])
                           if a['appearance'] == 'luminosity'), 'light')
        require(appearance not in result, f'Duplicate appearance in {folder}')
        result[appearance] = folder / entry['filename']
    return result

def check(path, size):
    properties = subprocess.check_output(
        ['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', '-g', 'hasAlpha', str(path)], text=True)
    values = dict(line.strip().split(': ', 1) for line in properties.splitlines() if ': ' in line)
    require(values.get('pixelWidth') == str(size), f'Unexpected width: {path}')
    require(values.get('pixelHeight') == str(size), f'Unexpected height: {path}')
    require(values.get('hasAlpha') == 'no', f'Unexpected alpha: {path}')

for color in ['Blue', 'Orange', 'Purple', 'Pink']:
    name = 'AppIcon' + ('' if color == 'Blue' else color)
    variants = images(catalog / (name + '.appiconset'))
    require(set(variants) == {'light', 'dark', 'tinted'}, name)
    for path in variants.values():
        check(path, 1024)
    for appearance in ['Light', 'Dark']:
        preview = images(catalog / ('IconPreview' + color + appearance + '.imageset'))
        require(set(preview) == {'light'}, preview)
        check(preview['light'], 128)

launch = images(catalog / 'IllucetLaunchBrand.imageset')
require(set(launch) == {'light', 'dark'}, launch)
for path in launch.values():
    check(path, 1024)
print('Four Illucet icon sets, eight previews and light/dark launch artwork are valid.')
PY
