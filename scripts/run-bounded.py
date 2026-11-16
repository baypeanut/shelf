#!/usr/bin/env python3
"""Bound standalone compiler/test execution and retain diagnostics locally."""
import os
from pathlib import Path
import signal
import subprocess
import sys

seconds, log, *command = sys.argv[1:]
path = Path(log)
path.parent.mkdir(parents=True, exist_ok=True)
with path.open('w') as output:
    process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = process.wait(timeout=float(seconds))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        sys.exit(f'Standalone command timed out after {seconds}s; diagnostics: {path}')
if code:
    sys.exit(f'Standalone command failed; diagnostics: {path}')
print(path.read_text(), end='')
