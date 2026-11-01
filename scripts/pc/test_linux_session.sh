#!/usr/bin/env bash
# Disposable hosted-runner session, with a real Secret Service and X server.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]]
[[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]]
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
private=$(mktemp -d "${RUNNER_TEMP:-/tmp}/cake-pc-session-XXXXXX")
export XDG_CONFIG_HOME="$private/config"
export XDG_DATA_HOME="$private/data"
export XDG_CACHE_HOME="$private/cache"
export XDG_RUNTIME_DIR="$private/runtime"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$private" "$XDG_RUNTIME_DIR"
trap 'gnome-keyring-daemon --stop >/dev/null 2>&1 || true; rm -rf "$private"' EXIT
# This is a random password for an empty CI-only keyring, never a user password.
keyring_password=$(head -c 32 /dev/urandom | base64)
eval "$(printf '%s' "$keyring_password" | gnome-keyring-daemon --unlock --components=secrets)"
unset keyring_password
export GNOME_KEYRING_CONTROL
export CAKE_WALLET_DIR="$private/onboarding"
mkdir -p "$CAKE_WALLET_DIR"
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11
xvfb-run -a -s '-screen 0 1280x800x24' flutter test integration_test/windows_startup_test.dart -d linux --timeout 4m --reporter expanded --dart-define-from-file=build/pc-linux-env.json
