#!/usr/bin/env python3
"""Shared, validated distribution metadata; private signing keys never live here."""
import base64
import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = 'felixhui6791-art/DeskNest'


def configuration(channel):
    if channel not in ('release', 'beta'):
        raise ValueError('channel must be release or beta')
    data = json.loads((ROOT / 'config' / f'{channel}.json').read_text())
    if data['channel'] != channel or not isinstance(data['build'], int) or data['build'] <= 0:
        raise ValueError('invalid channel/build configuration')
    pattern = r'\d+\.\d+\.\d+' if channel == 'release' else r'\d+\.\d+\.\d+-beta\.\d+'
    if not re.fullmatch(pattern, data['version']):
        raise ValueError('version does not match distribution channel')
    if len(base64.b64decode(data['publicKey'], validate=True)) != 32:
        raise ValueError('invalid Sparkle public key')
    data['appName'] = '栖桌' if channel == 'release' else '栖桌 测试版'
    data['bundleID'] = 'com.hui.desknest' + ('.beta' if channel == 'beta' else '')
    data['tag'] = 'v' + data['version']
    data['archive'] = 'DeskNest-' + data['version'] + '-universal.zip'
    data['feedURL'] = f'https://raw.githubusercontent.com/{REPO}/main/updates/{channel}.xml'
    return data


def app_info(data):
    return dict(CFBundleDevelopmentRegion='zh_CN', CFBundleExecutable='DeskNest',
                CFBundleIdentifier=data['bundleID'], CFBundleName=data['appName'],
                CFBundleDisplayName=data['appName'], CFBundlePackageType='APPL',
                CFBundleShortVersionString=data['version'], CFBundleVersion=str(data['build']),
                LSMinimumSystemVersion='14.0', LSUIElement=True, NSHighResolutionCapable=True,
                NSPrincipalClass='NSApplication', DeskNestChannel=data['channel'],
                SUFeedURL=data['feedURL'], SUPublicEDKey=data['publicKey'],
                SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False,
                SUScheduledCheckInterval=86400, SUEnableSystemProfiling=False,
                SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)


def main():
    command = sys.argv[1]
    if command == 'sparkle-root':
        paths = list((ROOT / '.build' / 'artifacts').glob('*/Sparkle/bin/generate_appcast'))
        if len(paths) != 1:
            raise ValueError('Run swift package resolve first; expected one Sparkle artifact')
        print(paths[0].parent.parent)
        return
    data = configuration(sys.argv[2])
    if command == 'plist':
        Path(sys.argv[3]).write_bytes(plistlib.dumps(app_info(data)))
    elif command == 'get':
        print(data[sys.argv[3]])
    else:
        raise ValueError('unknown distribution command')


if __name__ == '__main__':
    main()
