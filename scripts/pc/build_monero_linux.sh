#!/usr/bin/env bash
# Build Linux XMR from the exact revision used by the Dart wrapper.
# Preserve upstream checksums and dependency recipes; only select Release.
set -euo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
monero_c_commit=33671871de3d51696b66ffb3bd94f744e26974f6
monero_commit=22578c3f7d7b4b6dd85ff7daa42a827d97cc53d0
simplybs_commit=9b1e86953fde5827d903243fc230ad66d39b6de0
# Same source layout as the existing Windows cross-build, to reuse tool downloads.
source_dir="$root_dir/build/windows-native-src/monero_c"
output_dir="$root_dir/build/linux-native/monero"
target=x86_64-linux-gnu
jobs="${MONERO_BUILD_JOBS:-2}"
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]]
[[ ! "$root_dir" =~ [[:space:]] && "$jobs" =~ ^[1-9][0-9]*$ ]]
for tool in git go make clang llvm-ar gcc g++ patch python3 objdump xz readelf; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
python3 - "$(go env GOVERSION)" "$root_dir/pubspec_overrides.yaml" "$monero_c_commit" <<'PY'
import pathlib, re, sys
version = re.search(r'go(\d+)\.(\d+)', sys.argv[1])
if not version or tuple(map(int, version.groups())) < (1, 25):
    raise SystemExit('The pinned SimplyBS build requires Go 1.25 or newer.')
text = pathlib.Path(sys.argv[2]).read_text()
block = re.search(r'(?ms)^  monero:\n(.*?)(?=^  \S|\Z)', text)
if not block or not re.search(r'(?m)^      ref: ' + sys.argv[3] + r'\s*$', block[1]):
    raise SystemExit('Native Monero revision differs from Dart.')
PY
mkdir -p "$(dirname "$source_dir")" "$output_dir"
rm -f "$output_dir/native-build-info.json"
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --filter=blob:none --no-checkout https://github.com/MrCyjaneK/monero_c.git "$source_dir"
  git -C "$source_dir" checkout --detach "$monero_c_commit"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$monero_c_commit" ]]
git -C "$source_dir" describe --tags >/dev/null
git -C "$source_dir" diff --exit-code HEAD -- apply_patches.sh build_single.sh contrib/depends monero_libwallet2_api_c impls/monero.dart
python3 - "$source_dir" "$monero_commit" "$simplybs_commit" <<'PY'
import hashlib, pathlib, re, subprocess, sys
source = pathlib.Path(sys.argv[1])
backend = subprocess.check_output(['git','-C',str(source),'ls-tree','HEAD','monero'],text=True).split()[2]
if backend != sys.argv[2]:
    raise SystemExit('Unexpected Monero submodule revision.')
makefile = (source/'contrib/depends/Makefile').read_text()
if not re.search(r'^SIMPLYBS_HASH\s*=\s*' + sys.argv[3] + r'\s*$',makefile,re.M):
    raise SystemExit('Unexpected SimplyBS revision.')
wrapper = source/'monero_libwallet2_api_c'
cpp = wrapper/'src/main/cpp'
c_constants = (cpp/'monero_checksum.c').read_text()
dart_constants = (source/'impls/monero.dart/lib/src/checksum_monero.dart').read_text()
files = {'h':cpp/'monero_wallet2_api_c.h','cpp':cpp/'monero_wallet2_api_c.cpp','exp':wrapper/'monero_libwallet2_api_c.exp'}
for kind,path in files.items():
    expected = hashlib.sha256(path.read_bytes()).hexdigest()
    if kind == 'cpp': expected += '-' + backend
    symbol = 'wallet2_api_c_' + kind + '_sha256'
    for text in (c_constants,dart_constants):
        match = re.search(symbol + r'\s*=\s*"([^"]+)"',text)
        if not match or match[1] != expected:
            raise SystemExit('Source/Dart checksum mismatch: ' + symbol)
original = (source/'build_single.sh').read_text()
option = '-DCMAKE_BUILD_TYPE=Debug'
if original.count(option) != 1:
    raise SystemExit('Review the upstream build recipe before changing configuration.')
(source/'build_single.pc-release.sh').write_text(original.replace(option,'-DCMAKE_BUILD_TYPE=Release'))
PY
if [[ ! -f "$source_dir/monero/.patch-applied" ]]; then
  git -C "$source_dir" submodule update --init --recursive -- monero
  git -C "$source_dir/monero" config user.name 'Cake Wallet PC CI'
  git -C "$source_dir/monero" config user.email 'ci@users.noreply.github.com'
  (cd "$source_dir" && bash ./apply_patches.sh monero)
fi
(cd "$source_dir" && bash ./build_single.pc-release.sh monero "$target" "-j$jobs")
python3 - "$source_dir" "$output_dir" <<'PY'
import hashlib, json, pathlib, shutil, subprocess, sys
source,output = map(pathlib.Path,sys.argv[1:])
tag = subprocess.check_output(['git','-C',str(source),'describe','--tags'],text=True).strip()
library = source/'release'/tag/'x86_64-linux-gnu/libmonero_wallet2_api_c.so'
header = subprocess.check_output(['readelf','-h',str(library)],text=True)
if 'ELF64' not in header or 'Advanced Micro Devices X86-64' not in header:
    raise SystemExit('Native Monero is not an x86-64 ELF library')
shutil.copy2(library,output/library.name)
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
metadata = {
  'commit':'33671871de3d51696b66ffb3bd94f744e26974f6',
  'moneroCommit':'22578c3f7d7b4b6dd85ff7daa42a827d97cc53d0',
  'simplybsCommit':'9b1e86953fde5827d903243fc230ad66d39b6de0',
  'target':'x86_64-linux-gnu','buildType':'Release',
  'upstreamBuildScriptSha256':digest(source/'build_single.sh'),
  'releaseBuildScriptSha256':digest(source/'build_single.pc-release.sh'),
  'files':{library.name:digest(output/library.name)}
}
(output/'native-build-info.json').write_text(json.dumps(metadata,indent=2)+'\n')
(output/'monero-elf.txt').write_text(header+subprocess.check_output(['readelf','-d',str(library)],text=True))
print(json.dumps(metadata,indent=2))
PY
