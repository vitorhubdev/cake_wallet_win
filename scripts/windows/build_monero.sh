#!/usr/bin/env bash
# Build the native XMR library from the exact commit used by the Dart bindings.
# Follow monero_c's pinned SimplyBS toolchain and dependencies; do not substitute
# an older release DLL or rewrite the ABI checksums to make it appear compatible.
# The only build-recipe adjustment selects optimized Release instead of Debug.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
monero_c_commit=33671871de3d51696b66ffb3bd94f744e26974f6
monero_commit=22578c3f7d7b4b6dd85ff7daa42a827d97cc53d0
simplybs_commit=9b1e86953fde5827d903243fc230ad66d39b6de0
source_dir="$root_dir/build/windows-native-src/monero_c"
output_dir="$root_dir/build/windows-native/monero"
target=x86_64-w64-mingw32
jobs="${MONERO_BUILD_JOBS:-2}"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo 'Build Monero on an x86_64 Linux runner.' >&2
  exit 1
fi
if [[ "$root_dir" =~ [[:space:]] || ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo 'The upstream build requires a path without spaces and positive MONERO_BUILD_JOBS.' >&2
  exit 1
fi
for tool in git go make clang llvm-ar gcc g++ patch python3 objdump xz; do
  command -v "$tool" >/dev/null || {
    echo "Required build tool not found: $tool" >&2
    exit 1
  }
done
python3 - "$(go env GOVERSION)" "$root_dir/pubspec_overrides.yaml" "$monero_c_commit" <<'PY'
import pathlib
import re
import sys

version = re.search(r'go(\d+)\.(\d+)', sys.argv[1])
if not version or tuple(map(int, version.groups())) < (1, 25):
    raise SystemExit('The pinned SimplyBS build requires Go 1.25 or newer.')
text = pathlib.Path(sys.argv[2]).read_text()
block = re.search(r'(?ms)^  monero:\n(.*?)(?=^  \S|\Z)', text)
if not block or not re.search(r'(?m)^      ref: ' + sys.argv[3] + r'\s*$', block[1]):
    raise SystemExit('Native Monero commit does not match pubspec_overrides.yaml.')
PY

mkdir -p "$(dirname "$source_dir")" "$output_dir"
# A stale success manifest must never survive a failed rebuild.
rm -f "$output_dir/native-build-info.json"
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/MrCyjaneK/monero_c.git "$source_dir"
  git -C "$source_dir" checkout --detach "$monero_c_commit"
fi
if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$monero_c_commit" ]]; then
  echo "Unexpected source checkout at $source_dir; use a clean build directory." >&2
  exit 1
fi
# The official script uses git describe for its release path. Keep reachable tags.
git -C "$source_dir" describe --tags >/dev/null
git -C "$source_dir" diff --exit-code HEAD -- \
  apply_patches.sh build_single.sh contrib/depends monero_libwallet2_api_c impls/monero.dart

# Verify all checked-in checksums against actual wrapper sources and the Dart
# constants before spending time building the toolchain. Never regenerate them.
python3 - "$source_dir" "$monero_commit" "$simplybs_commit" <<'PY'
import hashlib
import pathlib
import re
import subprocess
import sys

source = pathlib.Path(sys.argv[1])
backend = subprocess.check_output(
    ['git', '-C', str(source), 'ls-tree', 'HEAD', 'monero'], text=True
).split()[2]
if backend != sys.argv[2]:
    raise SystemExit('Unexpected pinned Monero submodule.')
makefile = (source / 'contrib/depends/Makefile').read_text()
if not re.search(r'^SIMPLYBS_HASH\s*=\s*' + sys.argv[3] + r'\s*$', makefile, re.M):
    raise SystemExit('Unexpected SimplyBS toolchain pin.')
wrapper = source / 'monero_libwallet2_api_c'
cpp = wrapper / 'src/main/cpp'
c_constants = (cpp / 'monero_checksum.c').read_text()
dart_constants = (source / 'impls/monero.dart/lib/src/checksum_monero.dart').read_text()
files = {
    'h': cpp / 'monero_wallet2_api_c.h',
    'cpp': cpp / 'monero_wallet2_api_c.cpp',
    'exp': wrapper / 'monero_libwallet2_api_c.exp',
}
for kind, path in files.items():
    expected = hashlib.sha256(path.read_bytes()).hexdigest()
    if kind == 'cpp':
        expected += '-' + backend
    symbol = 'wallet2_api_c_' + kind + '_sha256'
    for text in (c_constants, dart_constants):
        match = re.search(symbol + r'\s*=\s*"([^"]+)"', text)
        if not match or match[1] != expected:
            raise SystemExit('Source/Dart checksum mismatch: ' + symbol)
    print(symbol + ': ' + expected)

# Keep the verified upstream script untouched. Its hardcoded Debug build leaves
# Monero's transaction scanning and cryptography unoptimized. Derive a script
# beside it with exactly one build-configuration substitution for this release.
original = (source / 'build_single.sh').read_text()
debug_option = '-DCMAKE_BUILD_TYPE=Debug'
if original.count(debug_option) != 1:
    raise SystemExit('Review the upstream build recipe before selecting Release.')
(source / 'build_single.windows-release.sh').write_text(
    original.replace(debug_option, '-DCMAKE_BUILD_TYPE=Release')
)
PY

# Only initialize XMR. Other coins are not enabled by this Windows profile.
if [[ ! -f "$source_dir/monero/.patch-applied" ]]; then
  git -C "$source_dir" submodule update --init --recursive -- monero
  git -C "$source_dir/monero" config user.name 'Cake Wallet Windows CI'
  git -C "$source_dir/monero" config user.email 'ci@users.noreply.github.com'
  (cd "$source_dir" && bash ./apply_patches.sh monero)
fi
# build_single.sh sets its own isolated toolchain environment. Run it as a child
# process so its environment changes cannot affect the packaging steps below.
(cd "$source_dir" && bash ./build_single.windows-release.sh monero "$target" "-j$jobs")

python3 - "$source_dir" "$output_dir" "$monero_c_commit" "$monero_commit" "$simplybs_commit" "$target" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys

source, output = map(pathlib.Path, sys.argv[1:3])
commit, backend, simplybs, target = sys.argv[3:]
release = subprocess.check_output(['git', '-C', str(source), 'describe', '--tags'], text=True).strip()
dll = source / 'release' / release / target / 'libmonero_wallet2_api_c.dll'
roots = [source / 'contrib/depends/_native', source / 'contrib/depends' / target]

# Only DLLs provided by Windows itself may remain external. Resolve everything
# else from the very same toolchain/dependency tree as the native Monero build.
system_dlls = {
    'advapi32.dll', 'bcrypt.dll', 'crypt32.dll', 'cryptbase.dll', 'dbghelp.dll',
    'dnsapi.dll', 'gdi32.dll', 'imm32.dll', 'iphlpapi.dll', 'kernel32.dll',
    'mpr.dll', 'msasn1.dll', 'msvcrt.dll', 'ncrypt.dll', 'netapi32.dll',
    'normaliz.dll', 'ntdll.dll', 'ole32.dll', 'oleaut32.dll', 'powrprof.dll',
    'psapi.dll', 'rpcrt4.dll', 'secur32.dll', 'setupapi.dll', 'shell32.dll',
    'shlwapi.dll', 'ucrtbase.dll', 'user32.dll', 'userenv.dll', 'version.dll',
    'winhttp.dll', 'wininet.dll', 'winmm.dll', 'winspool.drv', 'ws2_32.dll',
    'wtsapi32.dll',
}

def sha256(path):
    return hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()

def is_amd64_dll(path):
    # A multilib MinGW toolchain can contain x86 and x64 DLLs with identical
    # names. Only complete AMD64 PE32+ DLL headers belong in this package.
    try:
        with path.open('rb') as handle:
            dos = handle.read(64)
            if len(dos) != 64 or dos[:2] != b'MZ':
                return False
            pe_offset = struct.unpack_from('<I', dos, 0x3c)[0]
            if pe_offset < 64:
                return False
            handle.seek(pe_offset)
            coff = handle.read(24)
            if len(coff) != 24 or coff[:4] != b'PE\0\0':
                return False
            machine, sections = struct.unpack_from('<HH', coff, 4)
            optional_size, characteristics = struct.unpack_from('<HH', coff, 20)
            optional = handle.read(optional_size)
            return (machine == 0x8664 and sections > 0
                    and characteristics & 0x2000 != 0
                    and optional_size >= 112 and len(optional) == optional_size
                    and optional[:2] == b'\x0b\x02')
    except (OSError, ValueError, struct.error):
        return False

def inspect(path):
    data = path.read_bytes()
    if len(data) < 64 or data[:2] != b'MZ':
        raise SystemExit('Not a Windows PE file: ' + str(path))
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0' or struct.unpack_from('<H', data, pe + 4)[0] != 0x8664:
        raise SystemExit('Not an AMD64 Windows DLL: ' + str(path))
    report = subprocess.check_output(['objdump', '-p', str(path)], text=True)
    imports = sorted(set(re.findall(r'DLL Name:\s*([^\s]+)', report)), key=str.lower)
    return data, report, imports

if not dll.is_file():
    raise SystemExit('Upstream build did not produce ' + str(dll))
data, report, _ = inspect(dll)
required_exports = (
    'MONERO_checksum_wallet2_api_c_h', 'MONERO_checksum_wallet2_api_c_cpp',
    'MONERO_checksum_wallet2_api_c_exp', 'MONERO_WalletManagerFactory_getWalletManager',
    'MONERO_WalletManager_createWallet', 'MONERO_WalletManager_openWallet',
    'MONERO_WalletManager_closeWallet', 'MONERO_Wallet_status', 'MONERO_Wallet_address',
)
for name in required_exports:
    if not re.search(r'(?m)^\s*\[\s*\d+\]\s+' + re.escape(name) + r'\s*$', report):
        raise SystemExit('Missing native Monero export: ' + name)

expected = {}
constants = (source / 'impls/monero.dart/lib/src/checksum_monero.dart').read_text()
for kind in ('h', 'cpp', 'exp'):
    symbol = 'wallet2_api_c_' + kind + '_sha256'
    value = re.search(symbol + r'\s*=\s*"([^"]+)"', constants)[1]
    if value.encode('ascii') + b'\0' not in data:
        raise SystemExit('Native DLL is missing the exact pinned checksum: ' + symbol)
    expected[symbol] = value

# Index only extracted dependencies, not an unrelated host MinGW installation.
candidates = {}
for root in roots:
    for directory, _, names in os.walk(root):
        for name in names:
            if name.lower().endswith('.dll'):
                path = pathlib.Path(directory) / name
                if path.is_file() and is_amd64_dll(path):
                    candidates.setdefault(name.lower(), []).append(path)

files = {dll.name.lower(): dll}
imports_by_file = {}
reports = {}
queue = [dll]

def include_runtime(name, required_by):
    normalized = name.lower()
    if normalized in files:
        return
    options = candidates.get(normalized, [])
    if not options:
        raise SystemExit('Missing toolchain DLL required by ' + required_by + ': ' + name)
    hashes = {sha256(option) for option in options}
    if len(hashes) != 1:
        raise SystemExit('Conflicting runtime DLLs in the native toolchain: ' + name)
    runtime = sorted(options, key=str)[0]
    inspect(runtime)
    files[normalized] = runtime
    queue.append(runtime)

# MWEB also uses the POSIX MinGW runtime. Ship this same freshly built runtime
# for the whole application even if Monero's linker selects static pthreads.
include_runtime('libwinpthread-1.dll', 'the Windows MWEB library')
while queue:
    path = queue.pop(0)
    _, report, imports = inspect(path)
    reports[path.name] = report
    imports_by_file[path.name] = imports
    for name in imports:
        normalized = name.lower()
        if normalized in system_dlls or normalized.startswith(('api-ms-win-', 'ext-ms-win-')):
            continue
        include_runtime(name, path.name)

# Validate everything before replacing the previous output. All files here are
# generated build artifacts, never user wallets or application data.
for old in output.glob('*.dll'):
    old.unlink()
for path in files.values():
    shutil.copy2(path, output / path.name)
(output / 'monero-pe.txt').write_text('\n\n'.join(
    'FILE: ' + name + '\n' + reports[name] for name in sorted(reports)
))
manifest = {
    'commit': commit,
    'target': target,
    'repository': 'https://github.com/MrCyjaneK/monero_c',
    'moneroCommit': backend,
    'simplybsCommit': simplybs,
    'upstreamReleaseDescription': release,
    'buildCommand': 'bash ./build_single.windows-release.sh monero ' + target + ' -j${MONERO_BUILD_JOBS:-2}',
    'buildType': 'Release',
    'buildRecipeAdjustment': 'Only -DCMAKE_BUILD_TYPE=Debug replaced with -DCMAKE_BUILD_TYPE=Release',
    'upstreamBuildScriptSha256': sha256(source / 'build_single.sh'),
    'releaseBuildScriptSha256': sha256(source / 'build_single.windows-release.sh'),
    'checksums': expected,
    'files': {path.name: sha256(output / path.name) for path in sorted(files.values(), key=lambda p: p.name)},
    'imports': imports_by_file,
}
(output / 'native-build-info.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
PY

echo "Pinned Windows Monero DLL and matching runtimes ready in $output_dir"
