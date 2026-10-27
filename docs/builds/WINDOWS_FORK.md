# Cake Wallet Windows x64 — community fork

This is a community Windows build from `vitorhubdev/cake_wallet_win`, not an
official Cake Labs Windows release. The CI uses Windows Server 2022, Visual
Studio 2022, Flutter 3.41.9 and the upstream dependency pins.

## Download and run

Open **Actions → Windows x64 → latest successful run → Artifacts →
CakeWallet-Windows-x64**. Extract the artifact and then extract the portable
`CakeWallet-Windows-x64-*.zip` into a writable folder. Keep **all** DLLs and the
`data` folder beside `CakeWallet.exe`. Do not copy just the executable.

The bundle targets 64-bit Windows 10/11 on Intel/AMD. It is unsigned. Its
`SHA256SUMS.txt`, `build-info.json`, `build-pubspec.lock` and
`dependency-manifest.json` identify the build and inputs. Compare the ZIP hash
using PowerShell `Get-FileHash <file.zip> -Algorithm SHA256`.

## Build in GitHub Actions

Push code to `dev` or `windows-ci`, or run **Windows x64 → Run workflow**.
No Cake Labs repository secrets or private build runners are required. The
Linux job cross-compiles MWEB; the Windows job generates code, builds the app,
bundles the native runtimes and runs the launch checks before uploading it.

The portable archive is published only if the required checks pass. Logs and
launch diagnostics are separate artifacts. A successful build/launch does not
by itself establish synchronization, recovery, sending, hardware wallet or
commercial-service functionality.

## Scope and service limitations

The currency configuration follows the upstream Windows script: Monero,
Bitcoin/Litecoin, EVM chains, Nano, Bitcoin Cash, Solana, Tron and Dogecoin.
Zcash, Zano and Decred are not enabled in this Windows profile. MWEB is built
from source and included instead of leaving its Windows DLL missing.

Production service credentials belonging to Cake Labs are not included.
Integrations requiring those credentials (for example some swaps, buy/sell,
fiat quotes, WalletConnect and Lightning services) may be unavailable. The
bundled Torch package does not supply a Windows Tor library, and the pinned
BitBox Windows implementation is incomplete; do not assume those features
work merely because they appear in upstream documentation.

## Upgrades and data compatibility

`tool/configure_windows_secrets.dart` supplies fixed, public compatibility
constants specific to this fork. They are compiled into the app and are not
wallet seeds or API credentials. Do not regenerate them for each build:
changing them can prevent an update from reading existing PINs, encrypted
wallet passwords and backups. Real credentials continue to use the upstream
Windows secure storage implementation.

This fork does not claim file/backup compatibility with builds made with
different constants, including official Cake binaries. Keep the recovery
phrase securely before migrating between distinct builds. Validate creation,
closing/reopening and recovery with a new, empty wallet before using funds.

## Local build

Use the same pinned tool versions, PowerShell 7, Python 3.11+, Rust, LLVM,
Visual Studio's Desktop development with C++ workload, and NuGet. Prepare the
`windows-native` artifact with `scripts/windows/build_mweb.sh` on Linux/WSL,
then place it under `build/windows-native/` on Windows and run:

```powershell
./scripts/windows/build.ps1 -Version 6.5.0 -BuildNumber 1
```

Use a fresh Windows CI runner for `smoke_test.ps1`; it intentionally refuses
to run its startup check in a personal profile. Never provide real wallet
seeds to CI. The old `cakewallet.bat` is superseded by the PowerShell build.
