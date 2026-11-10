#!/usr/bin/env python3
"""Package the tested PC bundle without replacing the host glibc/graphics stack."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.request
from package_linux import REQUIRED, verify_bundle

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = 'd803aecf9de21461c7459c974ce5e3f2d92b70ed'
TOOLS = {
    'appimagetool': (
        'https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage',
        'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'),
    'runtime': (
        'https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64',
        '2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d'),
}
# These SONAMEs can differ between Ubuntu and rolling distributions. GTK3,
# glibc, libstdc++ and GPU/Wayland/X11 drivers remain host responsibilities.
# Bundling an older libstdc++ can break a newer host's Mesa drivers.
PRIVATE_LIBS = ('libjsoncpp.so.', 'libsecret-1.so.', 'libsqlite3.so.',
                'libssl.so.', 'libcrypto.so.', 'libusb-1.0.so.',
                'libayatana-', 'libdbusmenu-', 'libnotify.so.',
                'libgcrypt.so.', 'libgpg-error.so.')


def digest(path: Path) -> str:
    with path.open('rb') as src:
        return hashlib.file_digest(src, 'sha256').hexdigest()


def validate_layout(bundle: Path, version: str, build: int) -> dict:
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not 0 < build < 65535:
        raise ValueError('Invalid version/build')
    bundle = bundle.resolve(strict=True)
    for name in REQUIRED:
        if not (bundle / name).is_file() or (bundle / name).stat().st_size == 0:
            raise ValueError('Incomplete Linux bundle: ' + name)
    for path in bundle.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(bundle):
            raise ValueError('Bundle symlink escapes the application directory')
        if path.name.endswith('.keys') or path.name == '.cake-wallet.lock':
            raise ValueError('Refusing to package wallet/profile material')
    info = json.loads((bundle / 'build-info.json').read_text())
    if info.get('version') != f'{version}+{build}' or info.get('upstreamCommit') != UPSTREAM:
        raise ValueError('Bundle version/upstream provenance mismatch')
    if not re.fullmatch(r'[0-9a-f]{40}', info.get('commit', '')):
        raise ValueError('Missing exact application source commit')
    return info


def stage_appdir(bundle: Path, appdir: Path, icon: Path) -> Path:
    app = appdir / 'usr/bin'
    shutil.copytree(bundle, app, symlinks=True)
    for name in ('cake-wallet-pc', 'cake_wallet_pc'):
        (app / name).chmod(0o755)
    (appdir / 'AppRun').write_text('''#!/usr/bin/env bash
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# Keep the established profile and real system keyring. Never redirect HOME.
exec "$here/usr/bin/cake-wallet-pc" "$@"
''')
    (appdir / 'AppRun').chmod(0o755)
    (appdir / 'cake-wallet-pc.desktop').write_text('''[Desktop Entry]
Type=Application
Name=Cake Wallet PC
Exec=cake-wallet-pc
Icon=cake-wallet-pc
Terminal=false
Categories=Office;Finance;
StartupWMClass=io.github.vitorhubdev.CakeWalletPC
''')
    shutil.copy2(icon, appdir / 'cake-wallet-pc.png')
    (appdir / '.DirIcon').symlink_to('cake-wallet-pc.png')
    return app


def bundle_abi_dependencies(app: Path) -> list[dict]:
    environment = dict(os.environ, LD_LIBRARY_PATH=str(app / 'lib'))
    dependencies = {}
    for path in sorted(app.rglob('*')):
        if not path.is_file():
            continue
        with path.open('rb') as src:
            if src.read(4) != b'\x7fELF':
                continue
        result = subprocess.run(['ldd', str(path)], env=environment, text=True,
                                capture_output=True, timeout=30)
        output = result.stdout + result.stderr
        if result.returncode or 'not found' in output:
            raise ValueError('Unresolved packaged runtime: ' + str(path))
        for line in output.splitlines():
            match = re.match(r'\s*(\S+)\s+=>\s+(/\S+)\s+\(', line)
            if match and match[1].startswith(PRIVATE_LIBS):
                dependencies[match[1]] = Path(match[2]).resolve(strict=True)
    # sqlite3 is loaded via FFI on some builds, so DT_NEEDED is not enough.
    cache = subprocess.check_output(['ldconfig', '-p'], text=True, timeout=15)
    for soname in ('libsqlite3.so.0',):
        matches = re.findall(r'^\s*' + re.escape(soname) + r'\s+\([^\n]*x86-64[^\n]*\) => (/\S+)$', cache, re.M)
        if not matches:
            raise ValueError('Missing dynamically loaded library: ' + soname)
        dependencies[soname] = Path(matches[0]).resolve(strict=True)
    manifest = []
    for soname, source in sorted(dependencies.items()):
        target = app / 'lib' / soname
        if source.is_relative_to(app.resolve()):
            continue
        if not source.is_relative_to(Path('/usr/lib')) and not source.is_relative_to(Path('/lib')):
            raise ValueError('Refusing a non-system ABI dependency')
        owner = subprocess.check_output(['dpkg-query', '-S', str(source)], text=True, timeout=15)
        package = owner.split(': ', 1)[0].strip()
        version = subprocess.check_output(['dpkg-query', '-W', '-f=${Version}', package],
                                          text=True, timeout=15).strip()
        copyright_file = Path('/usr/share/doc') / package.split(':')[0] / 'copyright'
        if not copyright_file.is_file():
            raise ValueError('Missing dependency license: ' + package)
        licenses = app / 'third-party-licenses/linux-libraries'
        licenses.mkdir(parents=True, exist_ok=True)
        shutil.copy2(copyright_file, licenses / (package.replace(':', '_') + '.copyright'))
        if target.exists() and digest(target) != digest(source):
            raise ValueError('Conflicting library SONAME: ' + soname)
        shutil.copy2(source, target)
        manifest.append({'soname': soname, 'package': package, 'version': version,
                         'sha256': digest(target)})
    # sqlite3 may be opened by name rather than linked as an ELF dependency.
    sqlite = app / 'lib/libsqlite3.so.0'
    if sqlite.is_file() and not (app / 'lib/libsqlite3.so').exists():
        (app / 'lib/libsqlite3.so').symlink_to(sqlite.name)
    return manifest


def download_tool(name: str) -> Path:
    url, expected = TOOLS[name]
    cache = ROOT / 'scripts/.cache/appimage'
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / expected
    if target.is_file() and digest(target) == expected:
        target.chmod(0o755)
        return target
    partial = target.with_suffix('.partial')
    try:
        started = time.monotonic()
        request = urllib.request.Request(url, headers={'User-Agent': 'CakeWalletPC-build'})
        with urllib.request.urlopen(request, timeout=30) as response, partial.open('wb') as output:
            size = 0
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if time.monotonic() - started > 90:
                    raise TimeoutError('Packaging tool download exceeded 90 seconds')
                if size > 64 * 1024 * 1024:
                    raise ValueError('Packaging tool exceeds the allowed download size')
                output.write(chunk)
        if digest(partial) != expected:
            raise ValueError('Pinned AppImage tool checksum mismatch: ' + name)
        partial.replace(target)
        target.chmod(0o755)
        return target
    finally:
        partial.unlink(missing_ok=True)


def write_checksums(dist: Path, prefix: str) -> None:
    paths = sorted(path for path in dist.glob(prefix + '*')
                   if path.name.endswith(('.deb', '.tar.gz', '.AppImage')))
    (dist / 'SHA256SUMS-linux.txt').write_text(
        ''.join(f'{digest(path)}  {path.name}\n' for path in paths), encoding='ascii')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='6.5.3')
    parser.add_argument('--build', required=True, type=int)
    args = parser.parse_args()
    os_release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                      if '=' in line)
    if os_release.get('ID', '').strip('"') != 'ubuntu' or os_release.get('VERSION_ID', '').strip('"') != '24.04':
        raise RuntimeError('Package on Ubuntu 24.04 so bundled libraries match the declared baseline')
    bundle = ROOT / 'build/linux/x64/release/bundle'
    info = validate_layout(bundle, args.version, args.build)
    verify_bundle(bundle)
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    prefix = f'CakeWalletPC-Linux-x64-{args.version}-{args.build}'
    tool, runtime = download_tool('appimagetool'), download_tool('runtime')
    with tempfile.TemporaryDirectory(prefix='cake-pc-appimage-') as temporary:
        appdir = Path(temporary) / 'CakeWalletPC.AppDir'
        app = stage_appdir(bundle, appdir, ROOT / 'assets/images/cakewallet_logo.png')
        libraries = bundle_abi_dependencies(app)
        (app / 'appimage-build-info.json').write_text(json.dumps({
            'sourceCommit': info['commit'], 'upstreamCommit': UPSTREAM,
            'baseline': 'Ubuntu 24.04 x86-64; glibc >= 2.39; host GTK3 and Secret Service',
            'tools': {name: {'url': value[0], 'sha256': value[1]} for name, value in TOOLS.items()},
            'bundledSystemLibraries': libraries,
            'hostComponents': ['glibc', 'libstdc++', 'GTK3', 'graphics drivers', 'Secret Service'],
        }, indent=2) + '\n')
        verify_bundle(app)
        subprocess.run(['desktop-file-validate', str(appdir / 'cake-wallet-pc.desktop')],
                       check=True, timeout=15)
        epoch = subprocess.check_output(['git', 'show', '-s', '--format=%ct', 'HEAD'],
                                        cwd=ROOT, text=True, timeout=15).strip()
        environment = dict(os.environ, ARCH='x86_64', SOURCE_DATE_EPOCH=epoch)
        subprocess.run([str(tool), '--appimage-extract-and-run', '--runtime-file', str(runtime),
                        str(appdir), str(dist / (prefix + '.AppImage'))],
                       env=environment, check=True, timeout=300)
    output = dist / (prefix + '.AppImage')
    output.chmod(0o755)
    if output.stat().st_size < 1_000_000:
        raise ValueError('Unexpectedly small AppImage')
    write_checksums(dist, prefix)
    print(json.dumps({'appimage': output.name, 'sha256': digest(output),
                      'sourceCommit': info['commit'], 'crossDistroTests': 'required separately'}))

if __name__ == '__main__':
    main()
