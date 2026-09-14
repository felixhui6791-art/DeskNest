#!/usr/bin/env python3
import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

spec = importlib.util.spec_from_file_location('distribution', Path(__file__).with_name('distribution.py'))
dist = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dist)
channel, output = sys.argv[1], Path(sys.argv[2])
data = dist.configuration(channel)
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.parse(output / 'appcast.xml').findall('./channel/item')
item = next(i for i in items if i.findtext('s:version', namespaces=ns) == str(data['build']))
enclosure = item.find('enclosure')
archive = output / data['archive']
assert enclosure.get('url') == f"https://github.com/{dist.REPO}/releases/download/{data['tag']}/{data['archive']}"
assert int(enclosure.get('length')) == archive.stat().st_size
signature = enclosure.get('{' + ns['s'] + '}edSignature')
assert signature, 'missing archive signature'
sparkle = next((dist.ROOT / '.build/artifacts').glob('*/Sparkle/bin/sign_update'))
subprocess.run([str(sparkle), '--verify', '--account', 'desknest-felixhui6791-art', str(archive), signature], check=True)
with tempfile.TemporaryDirectory(prefix='desknest-verify-') as folder:
    subprocess.run(['ditto', '-x', '-k', str(archive), folder], check=True)
    app = Path(folder) / (data['appName'] + '.app')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    for key, value in dist.app_info(data).items():
        assert info[key] == value, key
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    subprocess.run(['lipo', str(app / 'Contents/MacOS/DeskNest'), '-verify_arch', 'arm64', 'x86_64'], check=True)
print('渠道、版本、通用架构、归档签名与应用签名验证通过。')
