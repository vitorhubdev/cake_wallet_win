#!/usr/bin/env bash
# Cross-compile the existing MWEB wallet library on the Linux CI runner.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_dir="$root_dir/build/windows-native/mweb"
mingw_cc="${MINGW_CC:-x86_64-w64-mingw32-gcc}"
mingw_cxx="${MINGW_CXX:-x86_64-w64-mingw32-g++}"
mingw_objdump="${MINGW_OBJDUMP:-x86_64-w64-mingw32-objdump}"

for tool in go "$mingw_cc" "$mingw_cxx" "$mingw_objdump"; do
  command -v "$tool" >/dev/null || {
    echo "Required build tool not found: $tool" >&2
    exit 1
  }
done

mkdir -p "$output_dir"
cd "$root_dir/cw_mweb/go"
go mod download
go mod verify
CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC="$mingw_cc" CXX="$mingw_cxx" \
  go build -mod=readonly -trimpath -ldflags='-s -w' -buildmode=c-shared \
  -o "$output_dir/mweb.dll" .

# The official Monero Windows DLL imports libwinpthread-1.dll as well. Ship
# the x64 MinGW runtime alongside the application instead of relying on PATH.
pthread_dll="$($mingw_cc -print-file-name=libwinpthread-1.dll)"
if [[ ! -f "$pthread_dll" ]]; then
  echo "The MinGW x64 libwinpthread-1.dll runtime was not found: $pthread_dll" >&2
  exit 1
fi
cp "$pthread_dll" "$output_dir/libwinpthread-1.dll"

test -s "$output_dir/mweb.dll"
test -s "$output_dir/mweb.h"
"$mingw_objdump" -p "$output_dir/mweb.dll" > "$output_dir/mweb-pe.txt"
grep -q 'FreeString' "$output_dir/mweb-pe.txt" || {
  echo 'The MWEB DLL is missing the required FreeString export' >&2
  exit 1
}
echo "Windows MWEB DLL, header and runtime ready in $output_dir"
