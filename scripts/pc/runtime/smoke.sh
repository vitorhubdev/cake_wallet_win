#!/usr/bin/env bash
# Run only inside the explicitly disposable CI container, as an unprivileged user.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]]
[[ $(id -u) != 0 && $# == 1 && -n ${DBUS_SESSION_BUS_ADDRESS:-} ]]
image=$(realpath "$1")
private=$(mktemp -d /tmp/cake-pc-runtime-XXXXXX)
export RUNNER_TEMP="$private"
export HOME="$private/home" XDG_CONFIG_HOME="$private/config"
export XDG_DATA_HOME="$private/data" XDG_CACHE_HOME="$private/cache"
export XDG_RUNTIME_DIR="$private/runtime"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$private" "$XDG_RUNTIME_DIR"
trap 'gnome-keyring-daemon --stop >/dev/null 2>&1 || true; rm -rf "$private"' EXIT
cd "$private"
# Extraction avoids privileged FUSE devices in CI. Native desktop FUSE and
# Wayland/GPU drivers remain separate manual validations, not implied passes.
"$image" --appimage-extract >/dev/null
python3 /source/scripts/pc/runtime/verify.py "$private/squashfs-root"
keyring_password=$(head -c 32 /dev/urandom | base64)
eval "$(printf '%s' "$keyring_password" | gnome-keyring-daemon --unlock --components=secrets)"
unset keyring_password
export GNOME_KEYRING_CONTROL
python3 - <<'PY'
import json, secrets, secretstorage
connection=secretstorage.dbus_init()
collection=secretstorage.get_default_collection(connection)
if collection.is_locked():
    raise RuntimeError('Disposable Secret Service did not unlock')
nonce=secrets.token_hex(16)
secret=secrets.token_bytes(32)
item=collection.create_item('Synthetic Cake PC CI canary',
    {'application':'cake-wallet-pc-ci','session':nonce},secret,replace=False)
try:
    if item.get_secret()!=secret:
        raise RuntimeError('Secret Service roundtrip failed')
finally:
    item.delete()
print(json.dumps({'secretService':'passed','syntheticCanaryDeleted':True,'userWalletAccess':False}))
PY
xvfb-run -a -s '-screen 0 1280x800x24' \
  python3 /source/scripts/pc/smoke_linux.py "$private/squashfs-root/AppRun"
