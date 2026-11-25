#!/usr/bin/env python3
"""Exercise model preparation and the packaged-bundle checks with synthetic bundles."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

prepare = load('prepare_search_models', 'prepare-search-models.py')
verify = load('verify_bundle', 'verify-bundle.py')

# Stands in for the model compiler: writes a compiled folder derived from the package.
FAKE_COMPILER = '''import pathlib, sys
package, out = map(pathlib.Path, sys.argv[1:])
target = out / (package.stem + '.mlmodelc')
(target / 'weights').mkdir(parents=True)
(target / 'model.mil').write_bytes(b'compiled:' + (package / 'Data/model.mlmodel').read_bytes())
(target / 'weights/weight.bin').write_bytes(b'synthetic weights')
'''

class ModelPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shelf-model-checks-')
        self.root = Path(self.temporary.name)
        self.out = self.root / 'models'
        package = self.out / 'synthetic.mlpackage'
        (package / 'Data').mkdir(parents=True)
        (package / 'Manifest.json').write_text('{}')
        (package / 'Data/model.mlmodel').write_bytes(b'synthetic model')
        self.saved = prepare.FILES, prepare.PACKAGE_FILES
        prepare.PACKAGE_FILES = ['Manifest.json', 'Data/model.mlmodel']
        prepare.FILES = {'synthetic.mlpackage/' + name: prepare.sha256(package / name) for name in prepare.PACKAGE_FILES}
        script = self.root / 'compiler.py'
        script.write_text(FAKE_COMPILER)
        self.compiler = (sys.executable, str(script))
    def tearDown(self):
        prepare.FILES, prepare.PACKAGE_FILES = self.saved
        self.temporary.cleanup()
    def test_stale_or_altered_compiled_model_is_replaced_by_a_fresh_compile(self):
        target = self.out / 'synthetic.mlmodelc'
        (target / 'weights').mkdir(parents=True)
        (target / 'weights/weight.bin').write_bytes(b'altered weights')
        (target / 'extra.bin').write_bytes(b'left over')
        manifest = prepare.compile_model(self.out, 'synthetic', self.compiler)
        self.assertEqual(sorted(manifest), ['model.mil', 'weights/weight.bin'])
        self.assertEqual((target / 'weights/weight.bin').read_bytes(), b'synthetic weights')
        self.assertFalse((target / 'extra.bin').exists())
        self.assertEqual(prepare.tree_manifest(target), manifest)
        self.assertEqual([path.name for path in self.out.iterdir() if path.name.startswith('.compile-')], [])
    def test_package_that_differs_from_its_pinned_files_is_not_compiled(self):
        package = self.out / 'synthetic.mlpackage'
        for change in ('alter', 'extra'):
            with self.subTest(change=change):
                path = package / ('Data/model.mlmodel' if change == 'alter' else 'Data/other.bin')
                original = path.read_bytes() if path.exists() else None
                path.write_bytes(b'not the pinned bytes')
                with self.assertRaises(RuntimeError): prepare.compile_model(self.out, 'synthetic', self.compiler)
                self.assertFalse((self.out / 'synthetic.mlmodelc').exists())
                if original is None: path.unlink()
                else: path.write_bytes(original)
    def test_links_inside_a_model_folder_are_refused(self):
        folder = self.root / 'linked'
        folder.mkdir()
        (folder / 'weight.bin').symlink_to(self.out / 'synthetic.mlpackage/Manifest.json')
        with self.assertRaises(RuntimeError): prepare.tree_manifest(folder)
        self.assertIsNone(verify.tree_manifest(folder))

class BundledModelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shelf-bundle-models-')
        self.models = Path(self.temporary.name) / 'CLIP'
        self.saved = verify.ASSET_HASHES
        verify.ASSET_HASHES = {}
        for name in ('clip-vocab.json', 'clip-merges.txt', 'LICENSE-MobileCLIP-S2', 'LICENSE-Apple-code', 'ACKNOWLEDGEMENTS-MobileCLIP'):
            self.models.mkdir(exist_ok=True)
            (self.models / name).write_text('synthetic')
        compiled = {}
        for name in verify.COMPILED_MODELS:
            (self.models / name / 'weights').mkdir(parents=True)
            (self.models / name / 'weights/weight.bin').write_bytes(b'synthetic weights ' + name.encode())
            (self.models / name / 'model.mil').write_text('synthetic program')
            compiled[name] = prepare.tree_manifest(self.models / name)
        self.provenance = {'model': 'MobileCLIP-S2', 'revision': verify.MODEL_REVISION, 'sha256': {}, 'compiled': compiled}
        self.write()
    def tearDown(self):
        verify.ASSET_HASHES = self.saved
        self.temporary.cleanup()
    def write(self):
        (self.models / 'model-source.json').write_text(json.dumps(self.provenance))
    def test_matching_compiled_models_pass(self):
        verify.check_models(self.models)
    def test_altered_extra_or_missing_compiled_files_are_rejected(self):
        weight = self.models / verify.COMPILED_MODELS[0] / 'weights/weight.bin'
        original = weight.read_bytes()
        # Eight altered bytes are enough to fail the check.
        weight.write_bytes(b'\0' * 8 + original[8:])
        with self.assertRaises(SystemExit): verify.check_models(self.models)
        weight.write_bytes(original)
        extra = self.models / verify.COMPILED_MODELS[1] / 'extra.bin'
        extra.write_bytes(b'extra')
        with self.assertRaises(SystemExit): verify.check_models(self.models)
        extra.unlink()
        verify.check_models(self.models)
        weight.unlink()
        with self.assertRaises(SystemExit): verify.check_models(self.models)
    def test_missing_or_empty_compiled_checksums_are_rejected(self):
        for compiled in (None, {}, {name: {} for name in verify.COMPILED_MODELS}):
            with self.subTest(compiled=compiled):
                self.provenance['compiled'] = compiled
                self.write()
                with self.assertRaises(SystemExit): verify.check_models(self.models)

class SignatureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shelf-bundle-signature-')
        self.app = Path(self.temporary.name) / 'Shelf.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Resources').mkdir()
        shutil.copyfile('/usr/bin/true', self.app / 'Contents/MacOS/Shelf')
        (self.app / 'Contents/MacOS/Shelf').chmod(0o755)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.example.synthetic', 'CFBundleExecutable': 'Shelf', 'CFBundlePackageType': 'APPL'}))
    def tearDown(self):
        self.temporary.cleanup()
    def sign(self, *options):
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', *options, str(self.app)], check=True, capture_output=True)
    def test_hardened_runtime_without_entitlements_passes(self):
        self.sign('--options', 'runtime')
        verify.check_signature(self.app)
    def test_missing_runtime_is_rejected(self):
        self.sign()
        with self.assertRaises(SystemExit): verify.check_signature(self.app)
    def test_any_entitlement_is_rejected(self):
        for key in ('com.apple.security.get-task-allow', 'com.apple.security.cs.disable-library-validation'):
            with self.subTest(key=key):
                entitlements = Path(self.temporary.name) / 'entitlements.plist'
                entitlements.write_bytes(plistlib.dumps({key: True}))
                self.sign('--options', 'runtime', '--entitlements', str(entitlements))
                with self.assertRaises(SystemExit): verify.check_signature(self.app)
    def test_nested_code_is_rejected(self):
        self.sign('--options', 'runtime')
        for place in ('Frameworks', 'PlugIns', 'XPCServices', 'Resources/helper', 'MacOS/helper'):
            with self.subTest(place=place):
                path = self.app / 'Contents' / place
                if '/' in place: shutil.copyfile('/usr/bin/true', path)
                else: path.mkdir()
                with self.assertRaises(SystemExit): verify.check_signature(self.app)
                if path.is_dir(): shutil.rmtree(path)
                else: path.unlink()
        self.sign('--options', 'runtime')
        verify.check_signature(self.app)
    def test_universal_binaries_with_64_bit_offsets_are_rejected_in_either_byte_order(self):
        path = self.app / 'Contents/Resources/helper'
        for magic in (b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
            with self.subTest(magic=magic):
                path.write_bytes(magic + b'\0' * 60)
                self.sign('--options', 'runtime')
                with self.assertRaisesRegex(SystemExit, 'Nested code'): verify.check_signature(self.app)
        path.unlink()
    def test_executable_files_outside_the_executable_folder_are_rejected(self):
        resources = self.app / 'Contents/Resources'
        script = resources / 'run.command'
        script.write_text('#!/bin/sh\n')
        (resources / 'CLIP/model.mlmodelc').mkdir(parents=True)
        (resources / 'CLIP/model.mlmodelc/weight.bin').write_bytes(b'synthetic weights')
        for mode in (0o755, 0o744, 0o701):
            with self.subTest(mode=oct(mode)):
                script.chmod(mode)
                self.sign('--options', 'runtime')
                with self.assertRaisesRegex(SystemExit, 'Executable files'): verify.check_signature(self.app)
        # Data files, folders and models with ordinary modes pass.
        script.chmod(0o644)
        self.sign('--options', 'runtime')
        verify.check_signature(self.app)

if __name__ == '__main__': unittest.main()
