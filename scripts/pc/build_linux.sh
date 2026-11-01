#!/usr/bin/env bash
# Cake Wallet PC Linux x64 build. Never substitutes fake secure storage.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
stage=${1:-all}
version=${2:-6.5.2}
build=${3:-1}
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]]
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $build =~ ^[1-9][0-9]*$ ]]
[[ $stage =~ ^(all|configure|generate|build)$ ]]
resolve() { flutter pub get --offline || flutter pub get; }
if [[ $stage == all || $stage == configure ]]; then
  mkdir -p build/linux-native/mweb
  (cd cw_mweb/go && go mod verify && CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -mod=readonly -trimpath -ldflags='-s -w' -buildmode=c-shared -o "$root/build/linux-native/mweb/libmweb.so" .)
  python3 scripts/windows/prepare_dependencies.py --platform linux --sources-only
  flutter config --enable-linux-desktop --no-analytics
  cp assets/images/cakewallet_logo.png assets/images/app_logo.png
  dart tool/generate_pubspec.dart
  dart tool/configure.dart --monero --bitcoin --ethereum --polygon --nano --bitcoinCash --solana --tron --dogecoin --base --arbitrum --bsc --robinhood
  python3 - "$version" "$build" <<'PY'
from pathlib import Path
import re,sys
p=Path('pubspec.yaml')
s,n=re.subn(r'^version: 0\.0\.0\s*$', 'version: '+sys.argv[1]+'+'+sys.argv[2],p.read_text(),flags=re.M)
if n != 1: raise SystemExit('Unexpected pubspec version schema')
p.write_text(s)
PY
  flutter pub get
  dart run tool/configure_windows_secrets.dart
  (cd cw_mweb && resolve && dart run ffigen --config ffigen_config.linux-pc.yaml && MWEB_NATIVE_TEST_LIBRARY="$root/build/linux-native/mweb/libmweb.so" flutter test test/native/mweb_ffi_native_test.dart --reporter expanded)
fi
if [[ $stage == all || $stage == generate ]]; then
  for package in cw_core cw_monero cw_bitcoin cw_evm cw_nano cw_bitcoin_cash cw_solana cw_tron cw_dogecoin; do
    (cd "$package" && resolve && dart run build_runner build --delete-conflicting-outputs)
  done
  resolve
  dart run build_runner build --delete-conflicting-outputs
  dart run tool/generate_localization.dart
  python3 scripts/pc/compile_graphics.py
  flutter test test/tool/windows_secrets_test.dart test/core/wallet_name_validator_test.dart test/reactions/on_current_node_change_test.dart test/reactions/check_connection_test.dart test/core/pc_node_display_address_test.dart test/core/monero_node_probe_test.dart test/evm --reporter expanded
  (cd cw_core && flutter test test/amount --reporter expanded)
fi
if [[ $stage == all || $stage == build ]]; then
  python3 scripts/windows/prepare_dependencies.py --platform linux --verify-monero
  python3 - "$version" "$build" <<'PY'
import json,pathlib,sys
config=json.loads(pathlib.Path('env.json').read_text())
config.update(CW_WIN_APP_NAME='Cake Wallet PC',CW_WIN_APP_PACKAGE_NAME='io.github.vitorhubdev.CakeWalletPC',CW_WIN_APP_VERSION=sys.argv[1],CW_WIN_APP_BUILD_NUMBER=sys.argv[2],CAKE_PC_PROFILE='true')
pathlib.Path('build/pc-linux-env.json').write_text(json.dumps(config))
PY
  flutter build linux --release --build-name "$version" --build-number "$build" --dart-define-from-file=build/pc-linux-env.json
  bundle=build/linux/x64/release/bundle
  cp LICENSE.md "$bundle/"
  cp pubspec.lock "$bundle/build-pubspec.lock"
  cp build/linux-native/dependency-manifest.json "$bundle/"
  cp scripts/pc/cake-wallet-pc "$bundle/cake-wallet-pc"
  chmod 755 "$bundle/cake-wallet-pc"
  cp docs/builds/CAKE_WALLET_PC.md "$bundle/README-PC.md"
  python3 - "$bundle" "$version" "$build" <<'PY'
import json,pathlib,subprocess,sys
bundle=pathlib.Path(sys.argv[1])
info={'repository':'vitorhubdev/cake_wallet_win','commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'version':sys.argv[2]+'+'+sys.argv[3],'upstreamVersion':'6.5.2','upstreamCommit':'4f792ca4a9981961bdc368ad34ba4c8d40c928b1','flutter':json.loads(subprocess.check_output(['flutter','--version','--machine'],text=True)),'configuration':'Linux x64 community build; real libsecret; no Cake production API keys'}
(bundle/'build-info.json').write_text(json.dumps(info,indent=2)+'\n')
PY
fi
