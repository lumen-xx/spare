#!/usr/bin/env python3
"""Build the reference Sparkle feed without generate_appcast's external cache."""
import json, pathlib, subprocess, sys, xml.etree.ElementTree as ET
from email.utils import formatdate
folder, version, build = sys.argv[1:]
folder = pathlib.Path(folder)
config = json.loads(pathlib.Path('updates/config.json').read_text())
archive = folder / f'Spare-{version}.zip'
sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', sparkle)
feed = folder / 'appcast.xml'
if feed.exists():
    root = ET.parse(feed).getroot()
else:
    root = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'Spare updates'
channel = root.find('channel')
item = ET.Element('item')
for name, text in [('title', f'Spare {version}'), ('pubDate', formatdate(usegmt=True)), (f'{{{sparkle}}}version', build), (f'{{{sparkle}}}shortVersionString', version), (f'{{{sparkle}}}minimumSystemVersion', '14.0'), (f'{{{sparkle}}}channel', 'preview')]:
    ET.SubElement(item, name).text = text
signature = subprocess.check_output(['.build/artifacts/sparkle/Sparkle/bin/sign_update', '--account', config['keychain_account'], '-p', str(archive)], text=True).strip()
ET.SubElement(item, 'enclosure', {'url': f"https://github.com/{config['repository']}/releases/download/v{version}/{archive.name}", 'length': str(archive.stat().st_size), 'type': 'application/octet-stream', f'{{{sparkle}}}edSignature': signature, f'{{{sparkle}}}os': 'macos'})
channel.insert(0, item)
ET.indent(root)
ET.ElementTree(root).write(feed, encoding='utf-8', xml_declaration=True)
