#!/usr/bin/env python3
"""Check the extracted artifact's provenance, private-library hashes and ELF loadability."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys

root=Path(sys.argv[1]).resolve(strict=True)
app=root/'usr/bin'
info=json.loads((app/'build-info.json').read_text())
metadata=json.loads((app/'appimage-build-info.json').read_text())
expected=os.environ['PC_SOURCE_COMMIT']
if info['commit']!=expected or metadata['sourceCommit']!=expected:
    raise RuntimeError('Artifact is not from this exact CI commit')
if info['upstreamCommit']!='d803aecf9de21461c7459c974ce5e3f2d92b70ed':
    raise RuntimeError('Unexpected upstream provenance')
if info['version']!=os.environ['PC_VERSION']+'+'+os.environ['PC_BUILD']:
    raise RuntimeError('Artifact version/build differs from the CI identity')
for entry in metadata['bundledSystemLibraries']:
    name=entry['soname']
    if Path(name).name!=name: raise RuntimeError('Unsafe library manifest')
    with (app/'lib'/name).open('rb') as source:
        actual=hashlib.file_digest(source,'sha256').hexdigest()
    if actual!=entry['sha256']: raise RuntimeError('Bundled library was modified')
count=0
for path in app.rglob('*'):
    if path.is_symlink() and not path.resolve().is_relative_to(root):
        raise RuntimeError('AppImage has an escaping symlink')
    if not path.is_file(): continue
    with path.open('rb') as source:
        if source.read(4)!=b'\x7fELF': continue
    result=subprocess.run(['ldd',str(path)],
        env=dict(os.environ,LD_LIBRARY_PATH=str(app/'lib')),
        text=True,capture_output=True,timeout=20)
    if result.returncode or 'not found' in result.stdout+result.stderr:
        missing=re.findall(r'^\s*(\S+)\s+=>\s+not found',result.stdout,re.M)
        raise RuntimeError('Unresolved ELF dependencies: '+path.name+' '+','.join(missing))
    count+=1
os_release=dict(line.split('=',1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
print(json.dumps({'elfDependencies':'passed','elfFiles':count,
    'distribution':os_release.get('PRETTY_NAME','').strip('"'),
    'sourceCommit':expected,'glibc':subprocess.check_output(['getconf','GNU_LIBC_VERSION'],text=True).strip(),
    'scope':'container ELF/runtime dependencies; not hardware, Wayland or payments'}))
