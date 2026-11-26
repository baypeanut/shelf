#!/usr/bin/env python3
"""Exercise malformed version input and bundle identity/version drift."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_version', Path(__file__).with_name('check-release-version.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shelf-release-version-')
        self.root = Path(self.temporary.name)
        self.version('1.0.0')
    def tearDown(self):
        self.temporary.cleanup()
    def version(self, value):
        (self.root / 'release-version.json').write_text(json.dumps({'version': value, 'build': '1'}))
    def bundle(self, **overrides):
        app = self.root / 'Shelf.app'
        (app / 'Contents').mkdir(parents=True, exist_ok=True)
        info = {'CFBundleIdentifier': 'com.baypeanut.Shelf', 'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '1'}
        info.update(overrides)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        return app
    def test_stable_version_and_matching_bundle(self):
        self.assertEqual(guard.check_release_version(self.root, app=self.bundle()), '1.0.0')
    def test_invalid_versions_rejected(self):
        for value in [None, 1, True, '', '01.0.0', '1.0', '1.0.0-beta', '1.0.0\n']:
            with self.subTest(value=value):
                self.version(value)
                with self.assertRaises(guard.ReleaseVersionError): guard.load_release_version(self.root)
    def test_selected_version_drift_rejected(self):
        with self.assertRaises(guard.ReleaseVersionError): guard.check_release_version(self.root, expected_version='2.0.0')
    def test_wrong_identity_and_version_rejected(self):
        for change in [{'CFBundleIdentifier': 'com.example.Other'}, {'CFBundleShortVersionString': '2.0.0'}, {'CFBundleVersion': '0'}, {'CFBundleVersion': '2'}]:
            with self.subTest(change=change):
                with self.assertRaises(guard.ReleaseVersionError): guard.check_release_version(self.root, app=self.bundle(**change))
    def test_malformed_json_and_missing_bundle_rejected(self):
        (self.root / 'release-version.json').write_text('[')
        with self.assertRaises(guard.ReleaseVersionError): guard.load_release_version(self.root)
        self.version('1.0.0')
        with self.assertRaises(guard.ReleaseVersionError): guard.check_release_version(self.root, app=self.root / 'Missing.app')

if __name__ == '__main__': unittest.main()
