#!/usr/bin/env python3
"""Copy only public AWS endpoints into the ignored native configuration."""
import argparse
import json
import os
from pathlib import Path
import re
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]


def configure(path):
    config = json.loads(path.read_text())
    outputs = config['outputs']
    urls = {}
    for key, output, scheme in [('AWS_API_URL','APIURL','https'),('AWS_WEBSOCKET_URL','WebSocketURL','wss')]:
        value = outputs[output]
        url = urlsplit(value)
        if (url.scheme != scheme or not url.hostname or not url.hostname.endswith('.execute-api.us-east-1.amazonaws.com')
                or url.username or url.password or url.query or url.fragment or url.port):
            raise SystemExit('Unexpected public development endpoint.')
        urls[key] = value.replace('://', ':/$()/')  # xcconfig otherwise treats // as a comment.
    target = ROOT / 'apps/ipad/Configuration/Secrets.xcconfig'
    original = target.read_text() if target.exists() else ''
    if original:
        backup = path.parent / 'previous-native-config.xcconfig'
        if not backup.exists():
            backup.write_text(original)
            backup.chmod(0o600)
    values = {'REMOTE_PROVIDER':'aws', **urls}
    text = original
    for key, value in values.items():
        line = key + ' = ' + value
        pattern = r'^' + re.escape(key) + r'\s*=.*$'
        text = re.sub(pattern, lambda _: line, text, flags=re.MULTILINE) if re.search(pattern,text,re.MULTILINE) else text + '\n' + line + '\n'
    target.write_text(text)
    os.chmod(target,0o600)
    print('Configured public AWS endpoints; existing local settings preserved.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config',type=Path,required=True)
    configure(parser.parse_args().config.resolve())
