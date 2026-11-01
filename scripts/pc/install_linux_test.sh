#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]]
[[ $# == 1 ]]
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
deb=$(realpath "$1")
# Only this community package is changed, on a fresh CI runner.
sudo apt-get install -y "$deb"
[[ $(readlink -f /usr/bin/cake-wallet-pc) == /opt/cake-wallet-pc/cake-wallet-pc ]]
cmp build/linux/x64/release/bundle/cake_wallet_pc /opt/cake-wallet-pc/cake_wallet_pc
profile=$(mktemp -d "${RUNNER_TEMP:-/tmp}/cake-pc-install-profile-XXXXXX")
trap 'rm -rf "$profile"' EXIT
sentinel="$profile/upgrade-sentinel"
printf '%s' 'ci-only-profile-preservation' > "$sentinel"
# An explicit user profile is not part of the package file list.
xvfb-run -a python3 scripts/pc/smoke_linux.py /usr/bin/cake-wallet-pc --profile "$profile"
sudo apt-get remove -y cake-wallet-pc
[[ $(cat "$sentinel") == ci-only-profile-preservation ]]
[[ ! -e /opt/cake-wallet-pc/cake_wallet_pc ]]
echo 'Linux installation, binary identity, launch, exclusion and non-destructive uninstall checks passed.'
