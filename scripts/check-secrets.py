#!/usr/bin/env python3
"""Run checksum-pinned Gitleaks with a positive detection control and redacted reports."""
from pathlib import Path
import argparse
import hashlib
import io
import json
import os
import platform
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '8.30.1'
ARCHIVES = {
    ('Darwin', 'arm64'): ('darwin_arm64', 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5'),
    ('Darwin', 'x86_64'): ('darwin_x64', 'dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709'),
    ('Linux', 'x86_64'): ('linux_x64', '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report-dir', type=Path, default=ROOT / 'local/security-scan')
    # A pull request is checked from the target branch's copy of this script
    # and rules, pointed at the pull request's checkout.
    parser.add_argument('--source', type=Path, default=ROOT, help='checkout to scan')
    parser.add_argument('--config', type=Path, default=None, help='rules file (default: .gitleaks.toml in the checkout)')
    args = parser.parse_args()
    source = args.source.resolve()
    config = (args.config or source / '.gitleaks.toml').resolve()
    if not config.is_file():
        raise SystemExit('Secret-scanner rules were not found')
    reports = args.report_dir.resolve()
    reports.mkdir(parents=True, exist_ok=True)
    suffix, checksum = ARCHIVES[(platform.system(), platform.machine())]
    url = f'https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/gitleaks_{VERSION}_{suffix}.tar.gz'
    # macOS's system curl uses the system trust store, including when a
    # separately installed Python has no configured CA bundle. TLS remains
    # verified and the downloaded archive must also match the pinned digest.
    archive = subprocess.check_output([
        'curl', '--fail', '--silent', '--show-error', '--location', '--proto', '=https',
        '--tlsv1.2', '--connect-timeout', '15', '--max-time', '60', url,
    ])
    if hashlib.sha256(archive).hexdigest() != checksum:
        raise SystemExit('Pinned secret-scanner checksum did not match')
    with tempfile.TemporaryDirectory(prefix='shelf-secret-scanner-') as temporary:
        executable = Path(temporary) / 'gitleaks'
        with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
            entry = tar.getmember('gitleaks')
            if not entry.isfile():
                raise SystemExit('Secret-scanner archive has an invalid executable')
            executable.write_bytes(tar.extractfile(entry).read())
        os.chmod(executable, 0o700)
        base = [str(executable), '--no-banner', '--redact=100', '--report-format', 'json']
        probe = Path(temporary) / 'probe.json'
        # A fresh, throwaway key proves the detector actually runs. It never
        # authorizes anything or enters a public report; it reaches disk only
        # in the temporary history control below, which is deleted afterwards.
        dummy = subprocess.check_output(['openssl', 'genrsa', '2048'], text=True, stderr=subprocess.DEVNULL)
        control = subprocess.run(base + ['--report-path', str(probe), 'stdin'], input=dummy, text=True,
                                 capture_output=True, cwd=source)
        if control.returncode != 1 or not probe.exists() or not json.loads(probe.read_text()):
            raise SystemExit('Secret scanner failed its positive detection control')

        def scan(operation, report, cwd):
            # Only the rules file decides; an ignore file in the checkout is not
            # read, and inline allow comments are not honoured.
            return subprocess.run(base + ['--config', str(config), '--gitleaks-ignore-path', temporary, '--ignore-gitleaks-allow',
                                          '--report-path', str(report)] + operation, capture_output=True, text=True, cwd=cwd)
        # Diffs are always read as text, so a checkout's .gitattributes cannot
        # hide a file's history as binary or run its own diff program.
        history = ['git', '.', '--log-opts=--all --text --no-textconv --no-ext-diff']
        # The same key, committed with an allow comment under a no-diff rule and
        # then removed, must still be found in history.
        repository = Path(temporary) / 'history-control'
        repository.mkdir()
        git = ['git', '-c', 'user.name=control', '-c', 'user.email=control@example.invalid', '-c', 'commit.gpgsign=false',
               '-c', 'core.hooksPath=/dev/null', '-C', str(repository)]
        subprocess.run(git + ['init', '-q'], check=True)
        (repository / '.gitattributes').write_text('*.txt -diff\n')
        (repository / 'key.txt').write_text(dummy.rstrip('\n') + ' # gitleaks:allow\n')
        subprocess.run(git + ['add', '.'], check=True)
        subprocess.run(git + ['commit', '-qm', 'add'], check=True)
        subprocess.run(git + ['rm', '-q', 'key.txt'], check=True)
        subprocess.run(git + ['commit', '-qm', 'remove'], check=True)
        probe = Path(temporary) / 'history-probe.json'
        control = scan(history, probe, repository)
        if control.returncode != 1 or not probe.exists() or not json.loads(probe.read_text()):
            raise SystemExit('Secret scanner failed its history detection control')
        operations = [('working-tree', ['dir', '.'])]
        if subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=source, capture_output=True).returncode == 0:
            operations.append(('all-public-history', history))
        for name, operation in operations:
            report = reports / (name + '.json')
            result = scan(operation, report, source)
            (reports / (name + '.log')).write_text(result.stdout + result.stderr)
            if result.returncode != 0:
                raise SystemExit(f'Secret scan rejected {name}; inspect the redacted report')
            print(f'Gitleaks {VERSION}: {name} passed; positive and history detection controls passed')

if __name__ == '__main__':
    main()
