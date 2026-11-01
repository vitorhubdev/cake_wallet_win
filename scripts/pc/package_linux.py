#!/usr/bin/env python3
"""Package the tested Linux bundle; includes dependencies instead of a lone ELF."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
REQUIRED = ['cake_wallet_pc', 'cake-wallet-pc', 'lib/libflutter_linux_gtk.so',
            'lib/libmonero_wallet2_api_c.so', 'lib/libmweb.so', 'lib/libapp.so',
            'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin',
            'build-info.json', 'dependency-manifest.json', 'LICENSE.md']

def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as src:
        for chunk in iter(lambda: src.read(1024*1024), b''):
            h.update(chunk)
    return h.hexdigest()

def verify_bundle(bundle: Path) -> None:
    for name in REQUIRED:
        path = bundle/name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError('Incomplete Linux bundle: '+name)
    environment = dict(os.environ, LD_LIBRARY_PATH=str(bundle/'lib'))
    for path in [bundle/'cake_wallet_pc', *sorted((bundle/'lib').rglob('*.so'))]:
        header = subprocess.check_output(['readelf','-h',str(path)], text=True)
        if 'ELF64' not in header or 'Advanced Micro Devices X86-64' not in header:
            raise ValueError('Not an x86-64 ELF: '+str(path))
        check = subprocess.run(['ldd',str(path)], env=environment, text=True, capture_output=True, timeout=30)
        if check.returncode or 'not found' in check.stdout:
            raise ValueError('Unresolved Linux runtime dependency: '+str(path)+'\n'+check.stdout+check.stderr)

def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version',default='6.5.2')
    parser.add_argument('--build',required=True,type=int)
    args=parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+',args.version) or not 0 < args.build < 65535:
        raise ValueError('Invalid version/build')
    bundle=ROOT/'build/linux/x64/release/bundle'
    verify_bundle(bundle)
    dist=ROOT/'dist'
    dist.mkdir(exist_ok=True)
    prefix=f'CakeWalletPC-Linux-x64-{args.version}-{args.build}'
    with tempfile.TemporaryDirectory(prefix='cake-pc-package-') as tmp:
        tmp=Path(tmp)
        stage=tmp/'deb'
        app=stage/'opt/cake-wallet-pc'
        shutil.copytree(bundle,app,symlinks=True)
        for executable in ['cake_wallet_pc','cake-wallet-pc']:
            (app/executable).chmod(0o755)
        # No script in this package modifies or removes profiles or keyrings.
        (stage/'usr/bin').mkdir(parents=True)
        (stage/'usr/bin/cake-wallet-pc').symlink_to('/opt/cake-wallet-pc/cake-wallet-pc')
        desktop=stage/'usr/share/applications/io.github.vitorhubdev.CakeWalletPC.desktop'
        desktop.parent.mkdir(parents=True)
        desktop.write_text('[Desktop Entry]\nType=Application\nName=Cake Wallet PC\nComment=Community desktop wallet for Monero and Ethereum\nExec=cake-wallet-pc\nIcon=io.github.vitorhubdev.CakeWalletPC\nTerminal=false\nCategories=Office;Finance;\nStartupWMClass=io.github.vitorhubdev.CakeWalletPC\n')
        icon=stage/'usr/share/icons/hicolor/256x256/apps/io.github.vitorhubdev.CakeWalletPC.png'
        icon.parent.mkdir(parents=True)
        shutil.copy2(ROOT/'assets/images/cakewallet_logo.png',icon)
        (stage/'DEBIAN').mkdir()
        installed_size=sum(p.stat().st_size for p in app.rglob('*') if p.is_file())//1024
        control=f'''Package: cake-wallet-pc
Version: {args.version}-{args.build}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Cake Wallet PC community <108148783+vitorhubdev@users.noreply.github.com>
Installed-Size: {installed_size}
Depends: libc6 (>= 2.35), libstdc++6 (>= 12), libgtk-3-0, libsecret-1-0, libjsoncpp25, libsqlite3-0, libblkid1, liblzma5, libssl3, libudev1, libusb-1.0-0, libayatana-appindicator3-1, libnotify4
Recommends: gnome-keyring
Homepage: https://github.com/vitorhubdev/cake_wallet_win
Description: Cake Wallet PC community desktop wallet
 Linux x86-64 build with real system keyring support and a separate profile.
 Based on upstream Cake Wallet 6.5.2. Not an official Cake Labs release.
'''
        (stage/'DEBIAN/control').write_text(control)
        for path in stage.rglob('*'):
            if path.is_dir(): path.chmod(0o755)
        (stage/'DEBIAN/control').chmod(0o644)
        deb=dist/(prefix+'.deb')
        subprocess.run(['dpkg-deb','--root-owner-group','--build',str(stage),str(deb)],check=True,timeout=120)
        subprocess.run(['dpkg-deb','--info',str(deb)],check=True,timeout=30)
        portable=tmp/prefix
        shutil.copytree(bundle,portable,symlinks=True)
        for name in ['cake-wallet-pc','cake_wallet_pc']: (portable/name).chmod(0o755)
        with tarfile.open(dist/(prefix+'.tar.gz'),'w:gz') as archive:
            archive.add(portable,arcname=prefix)
    checksums=''.join(f'{digest(path)}  {path.name}\n' for path in sorted(dist.glob(prefix+'*')))
    (dist/'SHA256SUMS-linux.txt').write_text(checksums,encoding='ascii')
    print(checksums,end='')

if __name__=='__main__': main()
