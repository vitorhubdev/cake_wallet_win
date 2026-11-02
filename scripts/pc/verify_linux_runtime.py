#!/usr/bin/env python3
"""Verify the pinned XMR ABI on the supported Linux host before building Flutter."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

HEADER_HASH = 'f1f24af3a9ae7e136c67fbbeffb1af0f7a3dd6cb70a7c43d5bd36a60fdb4a64f'
NATIVE_COMMIT = '33671871de3d51696b66ffb3bd94f744e26974f6'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    args = parser.parse_args()
    library = args.library.resolve(strict=True)
    metadata = json.loads((library.parent / 'native-build-info.json').read_text())
    if (metadata.get('commit') != NATIVE_COMMIT or
            metadata.get('target') != 'x86_64-linux-gnu' or
            metadata.get('buildType') != 'Release'):
        raise ValueError('Unexpected native build provenance')
    digest = hashlib.sha256(library.read_bytes()).hexdigest()
    if metadata.get('files') != {library.name: digest}:
        raise ValueError('Native library digest does not match its manifest')
    header = subprocess.check_output(['readelf', '-h', str(library)], text=True, timeout=15)
    if 'ELF64' not in header or 'Advanced Micro Devices X86-64' not in header:
        raise ValueError('Native Monero is not an x86-64 ELF library')
    versions = subprocess.check_output(
        ['readelf', '--version-info', str(library)], text=True, timeout=15)
    requirements = sorted(set(re.findall(r'(?:GLIBC|GLIBCXX)_[0-9.]+', versions)))
    host = subprocess.check_output(['getconf', 'GNU_LIBC_VERSION'], text=True, timeout=10).strip()
    match = re.fullmatch(r'glibc (\d+)\.(\d+)', host)
    if match is None or tuple(map(int, match.groups())) < (2, 39):
        raise RuntimeError('This Linux build requires the Ubuntu 24.04 runtime baseline (glibc >= 2.39).')
    environment = dict(os.environ)
    environment['LD_LIBRARY_PATH'] = str(library.parent)
    dependencies = subprocess.run(
        ['ldd', str(library)], env=environment, text=True, capture_output=True, timeout=20)
    if dependencies.returncode or 'not found' in dependencies.stdout or 'not found' in dependencies.stderr:
        missing = sorted(set(re.findall(r'(?:GLIBC|GLIBCXX)_[0-9.]+', dependencies.stdout + dependencies.stderr)))
        raise RuntimeError('Native runtime dependencies are unresolved: ' + ', '.join(missing))
    # No wallet is created and no wallet material or third-party diagnostic
    # output is printed. A child process bounds native initialization time.
    probe = '''import ctypes, sys
native = ctypes.CDLL(sys.argv[1])
function = native.MONERO_checksum_wallet2_api_c_h
function.argtypes = []
function.restype = ctypes.c_char_p
if function().decode('ascii') != sys.argv[2]:
    raise SystemExit(3)
'''
    result = subprocess.run(
        [sys.executable, '-c', probe, str(library), HEADER_HASH],
        env=environment, capture_output=True, timeout=20)
    if result.returncode:
        raise RuntimeError('Native dynamic loading or pinned ABI check failed; no wallet operations were attempted.')
    print(json.dumps({'status': 'passed', 'host': host, 'nativeSha256': digest,
                      'requiredVersions': requirements, 'abiHeaderMatched': True,
                      'walletOperations': False}, sort_keys=True))


if __name__ == '__main__':
    main()
