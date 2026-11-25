#!/usr/bin/env python3
"""Fetch pinned original MobileCLIP-S2 assets for offline, on-device search."""
import hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'local/models/MobileCLIP'
REV = '3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947'
# Original S2 release, distributed as Apple Sample Code (also declared by the
# pinned apple/coreml-mobileclip model card). MobileCLIP2 is a different release.
APPLE = '341ef058802f0e4e5ab13c02f0cb32a3a94e367b'
TOKENIZER = '48faa0fea4b08d74188b3841771aca6ff2c92852'
MODELS = ['mobileclip_s2_image', 'mobileclip_s2_text']
PACKAGE_FILES = ['Manifest.json', 'Data/com.apple.CoreML/model.mlmodel', 'Data/com.apple.CoreML/weights/weight.bin']
FILES = {
 'mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/model.mlmodel': '2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b',
 'mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin': '6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00',
 'mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/model.mlmodel': 'b8651b6d030bae419a9548b41c8fae11f96b59cfa21b6e532a4c4434522b4b80',
 'mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin': '8e8d5454f104b6cbb58d98bf11e038ff1f1943599efea111260a832f094cd0ce',
}

FILES.update({
 'mobileclip_s2_image.mlpackage/Manifest.json': '6a1a3f93b8dca6c237dbb5dc7b19bb3c987042d14860288304986c099d8796b6',
 'mobileclip_s2_text.mlpackage/Manifest.json': 'ea6a189d82fee2ee36eadb99022cda66a7f6b50a4bf9cc1d9541c7ea3b4242a0',
 'clip-vocab.json': '7aeb221a2a93047170070379743b49204c13d6993d9947323cd94b75c1f657ba',
 'clip-merges.txt': '7e0847f6fced8bd28a736dcaeab20e64ac19010771700197ba479a0a8e517d4f',
 'LICENSE-MobileCLIP-S2': 'a94a7a9c59509751580a31fa1ab3b418a97b01304549d382b8b96ca8fa85a179',
 'LICENSE-Apple-code': '7be983907ac2fa52c53e29ad8eca89d67d1e77bcc46a0271702845d0a1f4114d',
 'ACKNOWLEDGEMENTS-MobileCLIP': '1fdf63aae2e325e2efde1aed1d3cc9addb063ea60a31f40d2a564bd7c29ac283',
})


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def tree_manifest(folder):
    """SHA-256 of every file in a folder by relative path. Links and special files are refused."""
    folder = pathlib.Path(folder)
    if folder.is_symlink() or not folder.is_dir():
        raise RuntimeError('Not a model folder: ' + folder.name)
    manifest = {}
    for directory, folders, names in os.walk(folder):
        for name in folders + names:
            path = pathlib.Path(directory) / name
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                raise RuntimeError('Unexpected entry in model folder: ' + folder.name)
        for name in names:
            path = pathlib.Path(directory) / name
            manifest[path.relative_to(folder).as_posix()] = sha256(path)
    if not manifest:
        raise RuntimeError('Empty model folder: ' + folder.name)
    return dict(sorted(manifest.items()))


def fetch(url, path, expected):
    if not expected:
        raise RuntimeError('Missing checksum: ' + path.name)
    if path.is_file():
        if sha256(path) != expected:
            raise RuntimeError('Cached asset checksum mismatch: ' + path.name)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    stage = path.with_name(path.name + '.download')
    # Use system TLS trust even with standalone Python installations. Fetch to
    # a staging file, then verify pinned model bytes before publishing them.
    subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location',
                    '--proto', '=https', '--tlsv1.2', '--connect-timeout', '15',
                    '--max-time', '600', '--retry', '2', '--user-agent', 'Shelf-model-build',
                    '--output', str(stage), url], check=True)
    if sha256(stage) != expected:
        raise RuntimeError('Model checksum mismatch: ' + path.name)
    stage.replace(path)


def compile_model(out, name, compiler=('xcrun', 'coremlcompiler', 'compile')):
    """Compile the verified package into a fresh folder and move the result into
    place, replacing any earlier output. Returns the compiled files' hashes."""
    package = out / (name + '.mlpackage')
    expected = {suffix: FILES[name + '.mlpackage/' + suffix] for suffix in PACKAGE_FILES}
    if tree_manifest(package) != dict(sorted(expected.items())):
        raise RuntimeError('Model package does not match its pinned files: ' + name)
    target = out / (name + '.mlmodelc')
    with tempfile.TemporaryDirectory(prefix='.compile-', dir=out) as temporary:
        subprocess.run(list(compiler) + [str(package), temporary], check=True)
        compiled = pathlib.Path(temporary) / (name + '.mlmodelc')
        manifest = tree_manifest(compiled)
        if target.is_symlink() or target.is_file():
            target.unlink()
        elif target.exists():
            shutil.rmtree(target)
        compiled.rename(target)
    if tree_manifest(target) != manifest:
        raise RuntimeError('Compiled model changed while it was moved into place: ' + name)
    return manifest


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    compiled = {}
    for name in MODELS:
        for suffix in PACKAGE_FILES:
            path = name + '.mlpackage/' + suffix
            fetch(f'https://huggingface.co/apple/coreml-mobileclip/resolve/{REV}/{path}', OUT / path, FILES[path])
        compiled[name + '.mlmodelc'] = compile_model(OUT, name)
    for name in ['clip-vocab.json', 'clip-merges.txt']:
        fetch(f'https://raw.githubusercontent.com/apple-aiml-research/ml-mobileclip/{TOKENIZER}/ios_app/MobileCLIPExplore/Resources/{name}', OUT / name, FILES[name])
    fetch(f'https://raw.githubusercontent.com/apple-aiml-research/ml-mobileclip/{APPLE}/LICENSE_weights_data', OUT / 'LICENSE-MobileCLIP-S2', FILES['LICENSE-MobileCLIP-S2'])
    fetch(f'https://raw.githubusercontent.com/apple-aiml-research/ml-mobileclip/{APPLE}/LICENSE', OUT / 'LICENSE-Apple-code', FILES['LICENSE-Apple-code'])
    fetch(f'https://raw.githubusercontent.com/apple-aiml-research/ml-mobileclip/{APPLE}/ACKNOWLEDGEMENTS', OUT / 'ACKNOWLEDGEMENTS-MobileCLIP', FILES['ACKNOWLEDGEMENTS-MobileCLIP'])
    # The compiled hashes are recorded only after compiling from the verified
    # packages above; the bundle check compares the packaged models with them.
    (OUT / 'model-source.json').write_text(json.dumps({'model': 'MobileCLIP-S2', 'revision': REV, 'tokenizerRevision': TOKENIZER, 'originalModelLicenseRevision': APPLE, 'sha256': FILES, 'compiled': compiled}, indent=2) + '\n')
    print('Prepared offline search models:', OUT)


if __name__ == '__main__':
    try:
        main()
    except RuntimeError as error:
        sys.exit(str(error))
