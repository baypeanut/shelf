#!/usr/bin/env python3
"""Write only public update trust into a community bundle before signing."""
import base64
from pathlib import Path
import plistlib
import sys

FEED = 'https://github.com/baypeanut/shelf/releases/latest/download/appcast.xml'


def configure(info, config):
    if config.get('FeedURL') != FEED:
        raise ValueError('Shelf updates must use the official HTTPS release feed')
    key = config.get('PublicEDKey', '')
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError('The public Ed25519 key must be 32 bytes')
    info.update(SUFeedURL=FEED, SUPublicEDKey=key, SURequireSignedFeed=True,
                SUVerifyUpdateBeforeExtraction=True, SUEnableAutomaticChecks=True,
                SUEnableSystemProfiling=False, SUAllowsAutomaticUpdates=False,
                SUAutomaticallyUpdate=False, SUScheduledCheckInterval=3600,
                SUSignedFeedFailureExpirationInterval=0)
    return info


if __name__ == '__main__':
    path = Path(sys.argv[1])
    config = Path(__file__).resolve().parents[1]/'packaging/Updates.plist'
    path.write_bytes(plistlib.dumps(configure(plistlib.loads(path.read_bytes()), plistlib.loads(config.read_bytes()))))
